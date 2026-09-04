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
    def initialize(providers_json:, overrides:, history:, self_provider_name:)
      @history = history
      raw_list = providers_json.fetch('providers')
      @providers = raw_list.map { |raw| build(raw, overrides.fetch(raw['payment_system'], {}), self_provider_name) }
      seed_targets_and_state
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

    private

    def build(raw, override, self_provider_name)
      provider = Provider.new(raw)
      provider.self_provider = (raw['payment_system'] == self_provider_name)
      provider.requests_per_minute_limit = override['requests_per_minute_limit']
      provider.daily_turnover_min = override['daily_turnover_min']
      provider
    end

    # volume_share_pct — не задан в providers.json, выводим из фактической
    # доли объёма провайдера в истории (среди "боевых" провайдеров, self-provider
    # всегда целится в 0%, как и traffic_percentage у него).
    def seed_targets_and_state
      real_providers = @providers.reject(&:self_provider?)
      volume_by_provider = real_providers.to_h { |p| [p.payment_system, @history.stat(p.payment_system).volume] }
      total_real_volume = volume_by_provider.values.sum

      @providers.each do |provider|
        provider.volume_share_pct = volume_share_target(provider, volume_by_provider, total_real_volume)
        # providers.json уже содержит daily_approved_amount "на сейчас" — реальные данные,
        # берём как стартовую точку доли по объёму. Долю по количеству заявок "на сейчас"
        # providers.json не даёт вообще — оценивать её через средний чек из истории было бы
        # шатко (чек сильно варьируется), поэтому счётчик количества стартует с нуля и
        # честно отражает только заявки из текущей обрабатываемой очереди.
        provider.routed_volume = provider.daily_approved_amount.to_f
        provider.routed_count = 0
      end
    end

    def volume_share_target(provider, volume_by_provider, total_real_volume)
      return 0.0 if provider.self_provider? || total_real_volume.zero?

      (volume_by_provider.fetch(provider.payment_system, 0).to_f / total_real_volume * 100).round(1)
    end
  end
end
