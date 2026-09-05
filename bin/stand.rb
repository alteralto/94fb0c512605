#!/usr/bin/env ruby
# frozen_string_literal: true

# Демо-стенд роутинга: локальный HTTP-сервер поверх того же движка, что и bin/run.rb.
#
#   ruby bin/stand.rb [port]
#   -> http://127.0.0.1:8787
#
# Стенд нужен, чтобы показать вживую то, что иначе видно только в коде:
# параметры правил меняются на форме, движок пересчитывается целиком, и видно,
# как сдвинулось распределение, объяснения и рекомендации.
#
# Сервер написан на стандартной библиотеке (socket + json): никаких гемов и
# проприетарных зависимостей, вся логика роутинга — в lib/.

require 'socket'
require 'json'
require_relative '../lib/config_loader'
require_relative '../lib/history_stats'
require_relative '../lib/pipeline'

ROOT = File.expand_path('..', __dir__)
PORT = (ARGV[0] || 8787).to_i
HOST = '127.0.0.1'

BASE_CONFIG = RoutingEngine::ConfigLoader.load(File.join(ROOT, 'config', 'strategy.yml'))
HISTORY     = RoutingEngine::HistoryStats.new(File.join(ROOT, 'data', 'operations_history.csv'))
PROVIDERS   = JSON.parse(File.read(File.join(ROOT, 'data', 'providers.json')))
QUEUE       = JSON.parse(File.read(File.join(ROOT, 'data', 'operations_queue_10.json')))

MIME = { '.html' => 'text/html', '.css' => 'text/css', '.js' => 'application/javascript',
         '.svg' => 'image/svg+xml', '.png' => 'image/png', '.mp4' => 'video/mp4' }.freeze
# Отдаём и web/, и docs/: страница разбора показывает BPMN-схему из docs/.
SERVE_ROOTS = %w[web docs].freeze
BINARY_EXT = %w[.png .mp4].freeze

def run_pipeline(override)
  config = RoutingEngine::Pipeline.deep_merge(BASE_CONFIG, override)
  result = RoutingEngine::Pipeline.new(
    config: config, providers_json: PROVIDERS, history: HISTORY, queue_raw: QUEUE
  ).run
  { 'decisions' => result.decisions, 'report' => result.report, 'config' => config }
end

def initial_state
  {
    'base_config' => BASE_CONFIG,
    'providers' => PROVIDERS,
    'queue' => QUEUE,
    'run' => run_pipeline({})
  }
end

def respond(client, status, body, content_type)
  payload = body.to_s.dup.force_encoding(Encoding::BINARY)
  client.print("HTTP/1.1 #{status}\r\n")
  client.print("Content-Type: #{content_type}; charset=utf-8\r\n")
  client.print("Content-Length: #{payload.bytesize}\r\n")
  client.print("Cache-Control: no-store\r\n")
  client.print("Connection: close\r\n\r\n")
  client.print(payload)
end

def serve_file(client, path)
  file = SERVE_ROOTS.map { |root| File.join(ROOT, root, path.sub(%r{\A#{root}/}, '')) }
                    .find { |candidate| File.file?(candidate) }
  return respond(client, '404 Not Found', 'not found', 'text/plain') unless file

  ext = File.extname(file)
  body = BINARY_EXT.include?(ext) ? File.binread(file) : File.read(file, encoding: 'UTF-8')
  respond(client, '200 OK', body, MIME.fetch(ext, 'text/plain'))
end

def handle(client)
  request_line = client.gets
  return if request_line.nil?

  method, target, = request_line.split(' ')
  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, value = line.split(':', 2)
    headers[key.to_s.strip.downcase] = value.to_s.strip
  end
  body = headers['content-length'] ? client.read(headers['content-length'].to_i) : nil
  path = target.to_s.split('?').first

  case [method, path]
  when %w[GET /]         then serve_file(client, 'index.html')
  when %w[GET /review]   then serve_file(client, 'review.html')
  when %w[GET /api/state] then respond(client, '200 OK', JSON.generate(initial_state), 'application/json')
  when %w[POST /api/run]
    override = body.to_s.empty? ? {} : JSON.parse(body)
    respond(client, '200 OK', JSON.generate(run_pipeline(override)), 'application/json')
  else
    if method == 'GET' && path.to_s.start_with?('/') && !path.to_s.include?('..')
      serve_file(client, path.to_s.sub(%r{\A/}, ''))
    else
      respond(client, '404 Not Found', 'not found', 'text/plain')
    end
  end
rescue JSON::ParserError => e
  respond(client, '400 Bad Request', JSON.generate('error' => "некорректный JSON: #{e.message}"), 'application/json')
rescue StandardError => e
  warn("[stand] #{e.class}: #{e.message}")
  respond(client, '500 Internal Server Error', JSON.generate('error' => "#{e.class}: #{e.message}"), 'application/json')
ensure
  client.close rescue nil
end

server = TCPServer.new(HOST, PORT)
puts "Стенд роутинга: http://#{HOST}:#{PORT}"
puts "Очередь: #{QUEUE.size} заявок, провайдеров: #{PROVIDERS.size}. Ctrl+C — стоп."

loop do
  Thread.new(server.accept) { |client| handle(client) }
rescue Interrupt
  break
end
