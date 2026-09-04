# frozen_string_literal: true

module RoutingEngine
  # Детерминированная (seeded) симуляция:
  #  1) примет ли уже выбранный провайдер заявку в обработку — либо явно откажет
  #     (:declined, безопасно сразу идти к следующему), либо НЕ ОТВЕТИТ (:timeout —
  #     по условию кейса "отказывает ИЛИ НЕ ОТВЕЧАЕТ" это разные случаи: статус
  #     неизвестен, повтор без проверки рискует задвоить выплату; перед fallback
  #     симулируется идемпотентная проверка статуса по operation_id);
  #  2) итоговый simulated_result (approved/rejected/expired), по conversion_24h
  #     и историческому соотношению rejected/expired у провайдера;
  #  3) latency_sec — среднее историческое для провайдера+результата.
  # Seed фиксирован в config/strategy.yml -> прогон воспроизводим при перепроверке.
  class Simulator
    # Доля "не ответил" среди всех отказов на этапе приёма заявки в обработку —
    # именно эта доля требует идемпотентной проверки перед fallback, а не просто skip.
    TIMEOUT_SHARE_OF_DECLINES = 0.4

    def initialize(seed:, decline_base_rate:, history:)
      @rng = Random.new(seed)
      @decline_base_rate = decline_base_rate
      @history = history
    end

    # :accepted / :declined / :timeout
    def pre_attempt_outcome(provider)
      return :accepted if provider.self_provider?

      rate = @decline_base_rate + ((1 - provider.conversion_24h.to_f) * 0.1)
      return :accepted if @rng.rand >= rate

      @rng.rand < TIMEOUT_SHARE_OF_DECLINES ? :timeout : :declined
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
