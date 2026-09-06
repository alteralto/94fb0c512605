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
require 'yaml'
require_relative '../lib/config_loader'
require_relative '../lib/history_stats'
require_relative '../lib/pipeline'

ROOT = File.expand_path('..', __dir__)
PORT = (ARGV[0] || 8787).to_i
# По умолчанию слушаем только локально. На сервере поднимаем через
# STAND_HOST=0.0.0.0 — чтобы публичная выдача была осознанным решением,
# а не поведением по умолчанию.
HOST = ENV.fetch('STAND_HOST', '127.0.0.1')

BASE_CONFIG = RoutingEngine::ConfigLoader.load(File.join(ROOT, 'config', 'strategy.yml'))
HISTORY     = RoutingEngine::HistoryStats.new(File.join(ROOT, 'data', 'operations_history.csv'))
PROVIDERS   = JSON.parse(File.read(File.join(ROOT, 'data', 'providers.json')))
QUEUE       = JSON.parse(File.read(File.join(ROOT, 'data', 'operations_queue_10.json')))

# Стенд рассчитан на публичный адрес, поэтому у каждого соединения есть бюджет.
# Без них одна пустая TCP-сессия занимает поток навсегда (медленный клиент
# держит gets), а один POST с выдуманным Content-Length просит гигабайт памяти.
MAX_BODY_BYTES  = 256 * 1024
MAX_HEADER_LINE = 8 * 1024
MAX_HEADERS     = 64
SOCKET_TIMEOUT  = 15
MAX_CONCURRENT  = 24
RATE_WINDOW     = 10    # секунд
RATE_LIMIT      = 40    # запросов с одного адреса за окно

LOCK   = Mutex.new
ACTIVE = { count: 0 }
HITS   = {}

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
  # strategy_yml — та самая политика, которую собрали ползунками, в том же
  # формате, что читает bin/run.rb. Без неё стенд остаётся демкой: покрутил,
  # посмотрел и унести нечего.
  { 'decisions' => result.decisions, 'report' => result.report,
    'config' => config, 'strategy_yml' => config.to_yaml }
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
  client.print("X-Content-Type-Options: nosniff\r\n")
  client.print("X-Frame-Options: DENY\r\n")
  client.print("Referrer-Policy: no-referrer\r\n")
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

# Скользящее окно на адрес: /api/run гоняет весь движок, поэтому дешёвый цикл
# запросов не должен превращаться в бесплатную нагрузку на машину.
def rate_limited?(address)
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  LOCK.synchronize do
    HITS.delete_if { |_, times| times.empty? } if HITS.size > 512
    times = (HITS[address] ||= [])
    times.reject! { |at| now - at > RATE_WINDOW }
    times << now
    times.size > RATE_LIMIT
  end
end

def handle(client)
  address = (client.peeraddr[3] rescue 'unknown')
  return respond(client, '429 Too Many Requests', 'слишком часто', 'text/plain') if rate_limited?(address)

  request_line = client.gets(MAX_HEADER_LINE)
  return if request_line.nil?

  method, target, = request_line.split(' ')
  headers = {}
  seen = 0
  while (line = client.gets(MAX_HEADER_LINE)) && line != "\r\n"
    seen += 1
    return respond(client, '431 Request Header Fields Too Large', 'слишком много заголовков', 'text/plain') if seen > MAX_HEADERS

    key, value = line.split(':', 2)
    headers[key.to_s.strip.downcase] = value.to_s.strip
  end

  length = headers['content-length'].to_i
  return respond(client, '413 Payload Too Large', 'тело запроса слишком велико', 'text/plain') if length > MAX_BODY_BYTES

  body = length.positive? ? client.read(length) : nil
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
rescue IO::TimeoutError
  # Клиент открыл сокет и замолчал — поток не ждём, освобождаем.
  nil
rescue StandardError => e
  warn("[stand] #{e.class}: #{e.message}")
  respond(client, '500 Internal Server Error', JSON.generate('error' => "#{e.class}: #{e.message}"), 'application/json')
ensure
  client.close rescue nil
end

# Слот занимается до запуска потока: иначе потолок ничего не ограничивает —
# потоки успевают наплодиться раньше, чем счётчик о них узнает.
def take_slot
  LOCK.synchronize do
    next false if ACTIVE[:count] >= MAX_CONCURRENT

    ACTIVE[:count] += 1
    true
  end
end

server = TCPServer.new(HOST, PORT)
puts "Стенд роутинга: http://#{HOST}:#{PORT}"
puts "Очередь: #{QUEUE.size} заявок, провайдеров: #{PROVIDERS.size}. Ctrl+C — стоп."

loop do
  client = server.accept
  unless take_slot
    respond(client, '503 Service Unavailable', 'стенд занят, попробуйте через минуту', 'text/plain') rescue nil
    client.close rescue nil
    next
  end

  Thread.new(client) do |socket|
    # Бюджет времени на всё соединение целиком: медленный клиент не удерживает поток.
    socket.timeout = SOCKET_TIMEOUT if socket.respond_to?(:timeout=)
    handle(socket)
  ensure
    LOCK.synchronize { ACTIVE[:count] -= 1 }
  end
rescue Interrupt
  break
end
