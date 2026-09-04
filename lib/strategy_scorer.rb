# frozen_string_literal: true

module RoutingEngine
  # Soft-goals — ранжирование провайдеров, уже прошедших hard-constraints,
  # по нескольким целевым факторам, учитываемым совместно (взвешенный скоринг).
  # Формализует "явный приоритет политик" из ТЗ: конфликт целей решается не
  # if/else-цепочкой, а суммой взвешенных отклонений от целевых показателей.
  class StrategyScorer
    def initialize(weights:, amount_bands:, providers:)
      @weights = weights || {}
      @amount_bands = amount_bands || []
      @providers = providers
    end

    # Возвращает [score, факторы_для_объяснения]
    def score(provider, operation)
      factors = {
        count_share_gap: count_share_gap(provider),
        volume_share_gap: volume_share_gap(provider),
        conversion: provider.conversion_24h.to_f,
        cascade_priority: cascade_score(provider),
        turnover_min_gap: turnover_min_gap(provider),
        amount_band: amount_band_bonus(provider, operation)
      }
      total = factors.sum { |k, v| v * @weights.fetch(k.to_s, 0.0) }
      [total, factors]
    end

    private

    def count_totals
      @providers.sum(&:routed_count)
    end

    def volume_totals
      @providers.sum(&:routed_volume)
    end

    # Отклонения от целевой доли ограничены сверху: traffic_percentage и
    # volume_share_pct иногда указывают на разных провайдеров одновременно
    # (в этом кейсе так и есть — у quickpay доля по объёму в истории 55.6%
    # против целевых 25% по количеству), и без ограничения один фактор
    # перевешивал бы всю остальную стратегию. Клип держит факторы сравнимыми
    # по масштабу с conversion/cascade.
    GAP_CLAMP = 0.3

    # Положительное значение — провайдер недобирает свою целевую долю по количеству
    # заявок (traffic_percentage, полю из providers.json — приоритетный сигнал) ->
    # приоритет повышается.
    def count_share_gap(provider)
      target = provider.traffic_percentage.to_f
      total = count_totals
      actual = total.zero? ? 0.0 : (provider.routed_count.to_f / total * 100)
      ((target - actual) / 100.0).clamp(-GAP_CLAMP, GAP_CLAMP)
    end

    # То же самое, но по объёму (volume_share_pct — наша оценка из истории,
    # используется как вторичный, менее авторитетный сигнал через меньший вес в конфиге).
    def volume_share_gap(provider)
      target = provider.volume_share_pct.to_f
      total = volume_totals
      actual = total.zero? ? 0.0 : (provider.routed_volume.to_f / total * 100)
      ((target - actual) / 100.0).clamp(-GAP_CLAMP, GAP_CLAMP)
    end

    def cascade_score(provider)
      return 0.0 unless provider.priority && provider.priority.to_f.positive?

      1.0 / provider.priority
    end

    def turnover_min_gap(provider)
      return 0.0 unless provider.daily_turnover_min.to_f.positive?

      gap = provider.daily_turnover_min.to_f - provider.daily_approved_amount.to_f
      gap.positive? ? gap / provider.daily_turnover_min.to_f : 0.0
    end

    def amount_band_bonus(provider, operation)
      band = @amount_bands.find { |b| b['max_amount'].nil? || operation.amount <= b['max_amount'] }
      band && band['prefer'] == provider.payment_system ? 1.0 : 0.0
    end
  end
end
