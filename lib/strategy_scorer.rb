# frozen_string_literal: true

module RoutingEngine
  # Soft-goals — ранжирование провайдеров, уже прошедших hard-constraints,
  # по нескольким целевым факторам, учитываемым совместно (взвешенный скоринг).
  # Формализует "явный приоритет политик" из ТЗ: конфликт целей решается не
  # if/else-цепочкой, а суммой взвешенных отклонений от целевых показателей.
  #
  # Факторы лежат в реестре FACTORS. Добавить новое правило распределения —
  # значит дописать сюда одну запись и вес в config/strategy.yml: router,
  # объяснения и отчёт разбирают реестр сами, перечисления факторов поимённо
  # больше нигде нет.
  class StrategyScorer
    FACTORS = {}

    # Регистрация фактора: имя (= ключ веса в конфиге), человекочитаемая
    # подпись для объяснений и вычисление, возвращающее число.
    def self.factor(name, label, &calc)
      FACTORS[name.to_s] = { label: label, calc: calc }
    end

    # Отклонения от целевой доли ограничены сверху: traffic_percentage и
    # volume_share_pct иногда указывают на разных провайдеров одновременно
    # (в этом кейсе так и есть — у quickpay доля по объёму в истории 55.6%
    # против целевых 25% по количеству), и без ограничения один фактор
    # перевешивал бы всю остальную стратегию. Клип держит факторы сравнимыми
    # по масштабу с conversion/cascade.
    GAP_CLAMP = 0.3

    factor(:count_share_gap, 'недобор целевой доли по количеству заявок') do |p, _op, s|
      s.share_gap(p.effective_traffic_pct, p.routed_count, s.count_totals)
    end

    factor(:volume_share_gap, 'недобор целевой доли по объёму') do |p, _op, s|
      s.share_gap(p.effective_volume_share_pct, p.routed_volume, s.volume_totals)
    end

    factor(:conversion, 'конверсия (сглаженная оценка)') do |p, _op, _s|
      p.conversion_24h.to_f
    end

    factor(:cascade_priority, 'позиция в каскаде (priority)') do |p, _op, _s|
      p.priority && p.priority.to_f.positive? ? 1.0 / p.priority : 0.0
    end

    factor(:turnover_min_gap, 'недобор дневного финобязательства') do |p, _op, _s|
      min = p.daily_turnover_min.to_f
      next 0.0 unless min.positive?

      gap = min - p.daily_approved_amount.to_f
      gap.positive? ? gap / min : 0.0
    end

    factor(:amount_band, 'сумма заявки попадает в предпочтительный диапазон') do |p, op, s|
      s.amount_band_bonus(p, op)
    end

    # Текущая загрузка влияет на ВЫБОР, а не только на допуск: провайдер,
    # подошедший вплотную к своим лимитам, проигрывает более свободному даже
    # когда формально проходит проверки. Считается проективно — с учётом суммы
    # конкретной заявки, поэтому фактор зависит и от провайдера, и от операции.
    factor(:load_headroom, 'запас мощности до лимитов после этой заявки') do |p, op, s|
      s.load_headroom(p, op)
    end

    # Порог, ниже которого загрузка провайдера считается штатной. Различать
    # 15% и 65% занятости смысла нет — это не повод менять маршрут; значение
    # имеет только подход вплотную к лимиту. Порог настраивается конфигом.
    DEFAULT_PRESSURE_THRESHOLD = 0.8

    def initialize(weights:, amount_bands:, providers:, load: {})
      @weights = weights || {}
      @amount_bands = amount_bands || []
      @providers = providers
      @pressure_threshold = ((load || {})['pressure_threshold_pct'] || DEFAULT_PRESSURE_THRESHOLD * 100).to_f / 100.0
      warn_unknown_weights
    end

    # Возвращает [score, факторы_для_объяснения].
    # В объяснении лежит не только значение фактора, но и его вклад в сумму —
    # иначе по логу непонятно, что именно перевесило.
    def score(provider, operation)
      factors = {}
      total = 0.0
      FACTORS.each do |name, spec|
        weight = @weights.fetch(name, 0.0).to_f
        value = spec[:calc].call(provider, operation, self).to_f
        contribution = value * weight
        total += contribution
        factors[name] = { 'value' => value.round(4), 'weight' => weight,
                          'contribution' => contribution.round(4), 'label' => spec[:label] }
      end
      [total, factors]
    end

    def count_totals
      @providers.sum(&:routed_count)
    end

    def volume_totals
      @providers.sum(&:routed_volume)
    end

    # Положительное значение — провайдер недобирает свою целевую долю -> приоритет выше.
    # Цель берётся эффективная (после перераспределения доли недоступных провайдеров,
    # см. ProviderPool#recompute_effective_targets), иначе недостижимая чужая доля
    # вечно держала бы всех доступных в состоянии "перебрали".
    def share_gap(target_pct, actual_absolute, total)
      target = target_pct.to_f
      actual = total.zero? ? 0.0 : (actual_absolute.to_f / total * 100)
      ((target - actual) / 100.0).clamp(-GAP_CLAMP, GAP_CLAMP)
    end

    # 1.0 — загрузка штатная, 0.0 — провайдер после этой заявки упрётся в лимит.
    # Штраф начинается только за порогом pressure_threshold и внутри оставшегося
    # интервала растёт линейно: иначе фактор превращался бы в постоянную фору
    # самому пустому провайдеру и в одиночку определял бы всё распределение
    # (проверено — с линейной версией отклонение от целевых долей росло с 10 до 50 п.п.).
    #
    # Берётся самая напряжённая из осей: дневной лимит, число одновременных заявок,
    # сумма в обработке. Ось без лимита (self-provider) не учитывается.
    def load_headroom(provider, operation)
      utilization = projected_utilization(provider, operation)
      return 1.0 if utilization.nil? || utilization <= @pressure_threshold
      return 0.0 if @pressure_threshold >= 1.0

      excess = (utilization - @pressure_threshold) / (1.0 - @pressure_threshold)
      (1.0 - excess).clamp(0.0, 1.0)
    end

    # Доля исчерпания самого узкого лимита провайдера ПОСЛЕ этой заявки, или nil,
    # если у провайдера лимитов нет вовсе.
    def projected_utilization(provider, operation)
      utilizations = []
      if provider.daily_amount_limit.to_f.positive?
        utilizations << (provider.daily_approved_amount.to_f + operation.amount) / provider.daily_amount_limit
      end
      if provider.in_progress_count_limit.to_f.positive?
        utilizations << (provider.in_progress_count.to_i + 1).to_f / provider.in_progress_count_limit
      end
      if provider.in_progress_amount_limit.to_f.positive?
        utilizations << (provider.in_progress_amount.to_f + operation.amount) / provider.in_progress_amount_limit
      end
      utilizations.max
    end

    def amount_band_bonus(provider, operation)
      band = @amount_bands.find { |b| b['max_amount'].nil? || operation.amount <= b['max_amount'] }
      band && band['prefer'] == provider.payment_system ? 1.0 : 0.0
    end

    private

    # Опечатка в имени веса иначе молча обнуляет целое правило распределения.
    def warn_unknown_weights
      unknown = @weights.keys.map(&:to_s) - FACTORS.keys
      return if unknown.empty?

      warn("[config] веса без фактора в реестре StrategyScorer: #{unknown.join(', ')} — правило не применяется")
    end
  end
end
