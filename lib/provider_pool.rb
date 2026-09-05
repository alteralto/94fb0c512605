# frozen_string_literal: true

require_relative 'provider'

module RoutingEngine
  # Собирает провайдеров из providers.json + бизнес-параметров из конфига +
  # калибровки из истории. Новый провайдер добавляется просто дополнением
  # providers.json и (опционально) provider_overrides в конфиге — без правки кода.
  class ProviderPool
    # self_provider_name задаётся конфигом (не хардкод в коде) — так решение не
    # привязано к конкретному набору входных данных: переименуют self-provider
    # в тестовых providers.json — достаточно поправить config/strategy.yml.
    def initialize(providers_json:, overrides:, history:, self_provider_name:, conversion: {})
      @history = history
      @conversion_settings = conversion || {}
      raw_list = providers_json.fetch('providers')
      @providers = raw_list.map { |raw| build(raw, overrides.fetch(raw['payment_system'], {}), self_provider_name) }
      seed_targets_and_state
      blend_conversions
      recompute_effective_targets
    end

    def all
      @providers
    end

    def find(name)
      @providers.find { |p| p.payment_system == name }
    end

    def self_provider
      @providers.find(&:self_provider?)
    end

    # Цель, назначенная провайдеру, которому нельзя отдать ни одной заявки, —
    # это не задача роутера, а дефект входных данных: сколько трафика в него ни
    # направляй, доля не закроется. Поэтому доля недоступных перераспределяется
    # между остальными пропорционально их собственным целям, и сумма эффективных
    # целей снова равна 100%. Без этого доступные провайдеры вечно выглядят
    # "перебравшими план", скоринг давит их вниз, а рекомендации предлагают
    # снижать traffic_percentage тем, кто ни в чём не виноват.
    #
    # Пересчитывается перед каждой заявкой (Router#route): провайдер может стать
    # недоступным по ходу прогона — например исчерпать дневной лимит, — и с этого
    # момента его долю должны подхватывать оставшиеся.
    def recompute_effective_targets
      reachable = @providers.reject { |p| p.self_provider? || p.structurally_unavailable? }
      count_total = reachable.sum { |p| p.traffic_percentage.to_f }
      volume_total = reachable.sum { |p| p.volume_share_pct.to_f }

      @providers.each do |provider|
        if reachable.include?(provider)
          provider.effective_traffic_pct = normalize(provider.traffic_percentage, count_total)
          provider.effective_volume_share_pct = normalize(provider.volume_share_pct, volume_total)
        else
          provider.effective_traffic_pct = 0.0
          provider.effective_volume_share_pct = 0.0
        end
      end
    end

    # Провайдеры с ненулевой целевой долей, которым нельзя отдать ни одной заявки.
    # Отчёт обязан назвать их поимённо: это причина, по которой фактическое
    # распределение не сойдётся с providers.json ни при каких весах.
    def unreachable_targets
      @providers.reject(&:self_provider?).filter_map do |provider|
        reason = provider.unavailable_reason
        next if reason.nil? || provider.traffic_percentage.to_f.zero?

        { 'provider' => provider.payment_system, 'target_pct' => provider.traffic_percentage.to_f,
          'reason' => reason }
      end
    end

    private

    def normalize(value, total)
      return 0.0 if total.zero?

      (value.to_f / total * 100).round(2)
    end

    def build(raw, override, self_provider_name)
      provider = Provider.new(raw)
      provider.self_provider = (raw['payment_system'] == self_provider_name)
      apply_overrides(provider, override)
      provider
    end

    # Из конфига переопределяется ЛЮБОЙ параметр провайдера: и поля, которых нет
    # в providers.json (requests_per_minute_limit, daily_turnover_min), и штатные
    # поля (лимиты, конверсия, текущий оборот). Это то, что позволяет менять
    # условия сценария и бизнес-параметры провайдеров, не трогая ни входные данные,
    # ни код. Неизвестный ключ не роняет прогон — сообщаем и пропускаем.
    def apply_overrides(provider, override)
      override.each do |key, value|
        setter = "#{key}="
        unless provider.respond_to?(setter)
          warn("[config] неизвестный параметр провайдера '#{key}' у #{provider.payment_system} — пропущен")
          next
        end
        provider.public_send(setter, value)
      end
    end

    # volume_share_pct — не задан в providers.json, выводим из фактической
    # доли объёма провайдера в истории (среди "боевых" провайдеров, self-provider
    # всегда целится в 0%, как и traffic_percentage у него). Если значение явно
    # задано в provider_overrides — уважаем его и историей не перетираем.
    def seed_targets_and_state
      real_providers = @providers.reject(&:self_provider?)
      volume_by_provider = real_providers.to_h { |p| [p.payment_system, @history.stat(p.payment_system).volume] }
      total_real_volume = volume_by_provider.values.sum

      @providers.each do |provider|
        provider.volume_share_pct ||= volume_share_target(provider, volume_by_provider, total_real_volume)
        # providers.json уже содержит daily_approved_amount "на сейчас" — реальные данные,
        # берём как стартовую точку доли по объёму. Долю по количеству заявок "на сейчас"
        # providers.json не даёт вообще — оценивать её через средний чек из истории было бы
        # шатко (чек сильно варьируется), поэтому счётчик количества стартует с нуля и
        # честно отражает только заявки из текущей обрабатываемой очереди.
        provider.routed_volume = provider.daily_approved_amount.to_f
        provider.routed_count = 0
      end
    end

    # conversion_24h в providers.json — заявленная провайдером величина, и она
    # может расходиться с тем, что видно в истории (в этом кейсе payflow заявляет
    # 91%, а фактически проводит 47.4% на 19 попытках). Верить снапшоту вслепую
    # нельзя, выкидывать его тоже — при малой выборке история сама шумит.
    # Поэтому усреднение со сжатием: декларация входит как prior_strength
    # "виртуальных наблюдений", история — своими фактическими. Чем больше у
    # провайдера реальных попыток, тем меньше веса у декларации.
    # prior_strength = 0 -> верим только истории, очень большое -> только декларации.
    def blend_conversions
      prior = (@conversion_settings['prior_strength'] || 0).to_f
      @providers.each do |provider|
        declared = provider.conversion_24h.to_f
        provider.declared_conversion_24h = declared
        provider.observed_conversion_24h = @history.observed_conversion(provider.payment_system)
        provider.observed_sample = @history.sample_size(provider.payment_system)

        next if provider.observed_conversion_24h.nil? || (prior + provider.observed_sample).zero?

        approved = provider.observed_conversion_24h * provider.observed_sample
        provider.conversion_24h = ((declared * prior + approved) / (prior + provider.observed_sample)).round(4)
      end
    end

    def volume_share_target(provider, volume_by_provider, total_real_volume)
      return 0.0 if provider.self_provider? || total_real_volume.zero?

      (volume_by_provider.fetch(provider.payment_system, 0).to_f / total_real_volume * 100).round(1)
    end
  end
end
