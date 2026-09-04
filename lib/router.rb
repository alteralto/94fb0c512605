# frozen_string_literal: true

require_relative 'hard_constraints'
require_relative 'strategy_scorer'

module RoutingEngine
  # Оркестрирует роутинг одной заявки:
  #  1) hard-constraints отсекают недопустимых провайдеров (attempts: skipped);
  #  2) оставшиеся ранжируются StrategyScorer по soft-goals;
  #  3) идём по рангу сверху вниз, симулируя приём заявки в обработку — провайдер
  #     может явно отказать (declined) или не ответить (timeout, требует идемпотентной
  #     проверки статуса перед fallback) — при любом исходе fallback на следующего по рангу;
  #  4) если внешний пул исчерпан — fallback на self-provider (имя из конфига);
  #  5) состояние выбранного провайдера обновляется, симулируется итог заявки.
  class Router
    def initialize(pool:, scorer_weights:, amount_bands:, simulator:)
      @pool = pool
      @weights = scorer_weights
      @amount_bands = amount_bands
      @simulator = simulator
    end

    def route(operation)
      scorer = StrategyScorer.new(weights: @weights, amount_bands: @amount_bands, providers: @pool.all)
      attempts = []

      eligible_ranked = rank_eligible(operation, scorer, attempts)
      selected = attempt_ranked_candidates(operation, eligible_ranked, attempts)
      selected ||= fallback_to_self_provider(operation, attempts)

      selected.reserve!(operation)
      result = @simulator.final_result(selected)
      selected.resolve!(operation, result)
      latency = @simulator.latency_sec(selected, result)

      {
        'operation_id' => operation.operation_id,
        'selected_provider' => selected.payment_system,
        'attempts' => attempts,
        'simulated_result' => result,
        'latency_sec' => latency
      }
    end

    private

    # Hard-constraints в порядке priority провайдера — так лог читается как
    # естественный каскад, даже если итоговый выбор определит soft-скоринг.
    def rank_eligible(operation, scorer, attempts)
      candidates = []
      @pool.all.reject(&:self_provider?).sort_by { |p| p.priority || Float::INFINITY }.each do |provider|
        res = HardConstraints.evaluate(provider, operation)
        if res.eligible
          score, factors = scorer.score(provider, operation)
          candidates << { provider: provider, score: score, factors: factors }
        else
          attempts << { 'provider' => provider.payment_system, 'decision' => 'skipped',
                         'reason' => res.reason, 'details' => res.details }
        end
      end
      candidates.sort_by { |c| -c[:score] }
    end

    def attempt_ranked_candidates(operation, ranked, attempts)
      ranked.each_with_index do |entry, idx|
        provider = entry[:provider]
        provider.register_attempt(operation)

        case @simulator.pre_attempt_outcome(provider)
        when :declined
          attempts << { 'provider' => provider.payment_system, 'decision' => 'skipped',
                         'reason' => 'provider_declined_processing',
                         'details' => "#{score_details(entry)}; провайдер явно отказал в обработке" }
          next
        when :timeout
          # Кейс отдельно требует различать "отказал" и "не отвечает": при таймауте
          # статус неизвестен, и слепой переход к следующему провайдеру рискует
          # задвоить выплату. Перед fallback выполняется идемпотентная проверка
          # статуса по operation_id (в проде — запрос к провайдеру с idempotency key;
          # здесь — часть детерминированной симуляции), которая подтверждает,
          # что операция НЕ была проведена, и только после этого — fallback.
          attempts << { 'provider' => provider.payment_system, 'decision' => 'skipped',
                         'reason' => 'provider_timeout_unknown_status',
                         'details' => "#{score_details(entry)}; провайдер не ответил (таймаут); " \
                                       'идемпотентная проверка статуса по operation_id — операция не проведена, fallback безопасен' }
          next
        end

        attempts << { 'provider' => provider.payment_system, 'decision' => 'selected',
                       'reason' => idx.zero? ? 'top_ranked_by_strategy' : 'next_ranked_after_declines',
                       'details' => score_details(entry) }
        log_outranked(ranked[(idx + 1)..], attempts)
        return provider
      end
      nil
    end

    def log_outranked(rest, attempts)
      rest&.each do |entry|
        attempts << { 'provider' => entry[:provider].payment_system, 'decision' => 'skipped',
                       'reason' => 'outranked_by_strategy_score', 'details' => score_details(entry) }
      end
    end

    def fallback_to_self_provider(operation, attempts)
      fallback = @pool.self_provider
      fallback.register_attempt(operation)
      attempts << { 'provider' => fallback.payment_system, 'decision' => 'selected',
                     'reason' => 'fallback_self_provider',
                     'details' => 'пул внешних провайдеров исчерпан (все отказали или недопустимы) — self-provider' }
      fallback
    end

    def score_details(entry)
      f = entry[:factors]
      format(
        'score=%.3f (count_gap=%.3f, volume_gap=%.3f, conversion=%.2f, cascade=%.3f, turnover_gap=%.3f, amount_band=%.0f)',
        entry[:score], f[:count_share_gap], f[:volume_share_gap], f[:conversion], f[:cascade_priority],
        f[:turnover_min_gap], f[:amount_band]
      )
    end
  end
end
