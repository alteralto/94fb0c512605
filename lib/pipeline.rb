# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'history_stats'
require_relative 'provider_pool'
require_relative 'operation'
require_relative 'simulator'
require_relative 'router'
require_relative 'report_builder'

module RoutingEngine
  # Один прогон роутинга: конфиг + провайдеры + история + очередь -> решения и отчёт.
  #
  # Вынесено из bin/run.rb, чтобы батч-запуск (bin/run.rb) и интерактивный стенд
  # (bin/stand.rb) гоняли ровно одну и ту же логику. Пайплайн не пишет файлы и не
  # печатает в консоль — этим занимается вызывающая сторона.
  class Pipeline
    Result = Struct.new(:decisions, :report, :pool, :config, keyword_init: true)

    # Рекурсивное слияние конфигов: база из config/strategy.yml, поверх — правки
    # с формы стенда. nil в override означает "оставить значение базы".
    def self.deep_merge(base, override)
      return base if override.nil?
      return override unless base.is_a?(Hash) && override.is_a?(Hash)

      base.merge(override) do |_key, base_value, override_value|
        if base_value.is_a?(Hash) && override_value.is_a?(Hash)
          deep_merge(base_value, override_value)
        elsif override_value.nil?
          base_value
        else
          override_value
        end
      end
    end

    def initialize(config:, providers_json:, history:, queue_raw:, period: nil)
      @config = config
      @providers_json = providers_json
      @history = history
      @queue_raw = queue_raw
      @period = period || Time.now.strftime('%Y-%m-%d')
    end

    def run
      pool = build_pool
      router = build_router(pool)
      queue = @queue_raw.map { |raw| Operation.new(raw) }

      decisions = queue.map { |operation| router.route(operation) }
      report = ReportBuilder.new(pool: pool, decisions: decisions, period: @period).build

      Result.new(decisions: decisions, report: report, pool: pool, config: @config)
    end

    private

    def build_pool
      ProviderPool.new(
        providers_json: @providers_json,
        overrides: @config['provider_overrides'] || {},
        history: @history,
        self_provider_name: @config['self_provider_name'] || 'spacepayments',
        conversion: @config['conversion'] || {}
      )
    end

    def build_router(pool)
      simulator = Simulator.new(
        seed: @config.dig('simulation', 'seed') || 42,
        decline_base_rate: @config.dig('simulation', 'provider_decline_base_rate') || 0.05,
        history: @history
      )
      Router.new(
        pool: pool,
        scorer_weights: @config['weights'] || {},
        amount_bands: @config['amount_bands'] || [],
        load_settings: @config['load'] || {},
        simulator: simulator
      )
    end
  end
end
