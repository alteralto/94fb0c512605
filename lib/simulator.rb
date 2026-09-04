# frozen_string_literal: true

module RoutingEngine
  # Детерминированная (seeded) симуляция:
  #  1) откажет ли уже выбранный провайдер в обработке (-> fallback на следующего);
  #  2) итоговый simulated_result (approved/rejected/expired), по conversion_24h
  #     и историческому соотношению rejected/expired у провайдера;
  #  3) latency_sec — среднее историческое для провайдера+результата.
  # Seed фиксирован в config/strategy.yml -> прогон воспроизводим при перепроверке.
  class Simulator
    def initialize(seed:, decline_base_rate:, history:)
      @rng = Random.new(seed)
      @decline_base_rate = decline_base_rate
      @history = history
    end

    def provider_declines?(provider)
      return false if provider.self_provider?

      rate = @decline_base_rate + ((1 - provider.conversion_24h.to_f) * 0.1)
      @rng.rand < rate
    end

    def final_result(provider)
      conv = provider.self_provider? ? 0.97 : provider.conversion_24h.to_f
      return 'approved' if @rng.rand < conv

      @rng.rand < rejected_share(provider) ? 'rejected' : 'expired'
    end

    def latency_sec(provider, result)
      @history.avg_latency(provider.payment_system, result) || provider.avg_latency_sec.to_i
    end

    private

    def rejected_share(provider)
      stat = @history.stat(provider.payment_system)
      failed = stat.rejected_count + stat.expired_count
      return 0.5 if failed.zero?

      stat.rejected_count.to_f / failed
    end
  end
end
