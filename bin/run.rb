#!/usr/bin/env ruby
# frozen_string_literal: true

# Батч-прогон роутинга.
#
# Использование:
#   ruby bin/run.rb [queue.json] [providers.json] [history.csv] [strategy.yml] [decisions_out.json] [report_out.json]
#
# По умолчанию берёт публичные data/* и пишет routing_decisions_test.json /
# routing_report_test.json в корень репозитория.

require 'json'
require_relative '../lib/config_loader'
require_relative '../lib/history_stats'
require_relative '../lib/pipeline'

root = File.expand_path('..', __dir__)

queue_path     = ARGV[0] || File.join(root, 'data', 'operations_queue_10.json')
providers_path = ARGV[1] || File.join(root, 'data', 'providers.json')
history_path   = ARGV[2] || File.join(root, 'data', 'operations_history.csv')
config_path    = ARGV[3] || File.join(root, 'config', 'strategy.yml')
decisions_out  = ARGV[4] || File.join(root, 'routing_decisions_test.json')
report_out     = ARGV[5] || File.join(root, 'routing_report_test.json')

[queue_path, providers_path, history_path, config_path].each do |path|
  abort("Не найден входной файл: #{path}") unless File.exist?(path)
end

begin
  config    = RoutingEngine::ConfigLoader.load(config_path)
  history   = RoutingEngine::HistoryStats.new(history_path)
  providers = JSON.parse(File.read(providers_path))
  queue     = JSON.parse(File.read(queue_path))
rescue JSON::ParserError => e
  abort("Некорректный JSON во входных данных: #{e.message}")
end

abort('Очередь заявок пуста или не является массивом') unless queue.is_a?(Array) && !queue.empty?

result = RoutingEngine::Pipeline.new(
  config: config, providers_json: providers, history: history, queue_raw: queue
).run

File.write(decisions_out, JSON.pretty_generate(result.decisions))
File.write(report_out, JSON.pretty_generate(result.report))

puts "OK: обработано #{result.decisions.size} заявок"
puts "  -> #{decisions_out}"
puts "  -> #{report_out}"
