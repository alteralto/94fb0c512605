#!/usr/bin/env ruby
# frozen_string_literal: true

# Использование:
#   ruby bin/run.rb [queue.json] [providers.json] [history.csv] [strategy.yml] [decisions_out.json] [report_out.json]
# По умолчанию берёт публичные data/* и пишет routing_decisions_test.json / routing_report_test.json в корень репо.

require 'json'
require 'time'
require_relative '../lib/config_loader'
require_relative '../lib/history_stats'
require_relative '../lib/provider_pool'
require_relative '../lib/operation'
require_relative '../lib/simulator'
require_relative '../lib/router'
require_relative '../lib/report_builder'

root = File.expand_path('..', __dir__)

queue_path = ARGV[0] || File.join(root, 'data', 'operations_queue_10.json')
providers_path = ARGV[1] || File.join(root, 'data', 'providers.json')
history_path = ARGV[2] || File.join(root, 'data', 'operations_history.csv')
config_path = ARGV[3] || File.join(root, 'config', 'strategy.yml')
decisions_out = ARGV[4] || File.join(root, 'routing_decisions_test.json')
report_out = ARGV[5] || File.join(root, 'routing_report_test.json')

config = RoutingEngine::ConfigLoader.load(config_path)
history = RoutingEngine::HistoryStats.new(history_path)
providers_json = JSON.parse(File.read(providers_path))
pool = RoutingEngine::ProviderPool.new(
  providers_json: providers_json,
  overrides: config['provider_overrides'] || {},
  history: history,
  self_provider_name: config['self_provider_name'] || 'spacepayments'
)
queue = JSON.parse(File.read(queue_path)).map { |raw| RoutingEngine::Operation.new(raw) }

simulator = RoutingEngine::Simulator.new(
  seed: config.dig('simulation', 'seed') || 42,
  decline_base_rate: config.dig('simulation', 'provider_decline_base_rate') || 0.05,
  history: history
)

router = RoutingEngine::Router.new(
  pool: pool,
  scorer_weights: config['weights'] || {},
  amount_bands: config['amount_bands'] || [],
  simulator: simulator
)

decisions = queue.map { |op| router.route(op) }
File.write(decisions_out, JSON.pretty_generate(decisions))

report = RoutingEngine::ReportBuilder.new(pool: pool, decisions: decisions, period: Time.now.strftime('%Y-%m-%d')).build
File.write(report_out, JSON.pretty_generate(report))

puts "OK: обработано #{decisions.size} заявок"
puts "  -> #{decisions_out}"
puts "  -> #{report_out}"
