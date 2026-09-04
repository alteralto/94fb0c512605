# frozen_string_literal: true

require 'csv'

module RoutingEngine
  # Статистика по operations_history.csv: используется для калибровки
  # volume_share_pct, конверсии и латентности при симуляции — вместо
  # константных значений "с потолка".
  class HistoryStats
    Stat = Struct.new(:count, :volume, :approved_count, :rejected_count,
                       :expired_count, :latency_by_status, keyword_init: true)

    def initialize(csv_path)
      @by_provider = Hash.new do |h, k|
        h[k] = Stat.new(count: 0, volume: 0, approved_count: 0, rejected_count: 0,
                         expired_count: 0, latency_by_status: Hash.new { |hh, kk| hh[kk] = [] })
      end
      load(csv_path)
    end

    def stat(provider)
      @by_provider[provider]
    end

    def avg_latency(provider, status)
      arr = stat(provider).latency_by_status[status]
      return nil if arr.empty?

      (arr.sum.to_f / arr.size).round
    end

    private

    def load(csv_path)
      CSV.foreach(csv_path, headers: true) do |row|
        provider = row['payment_system']
        next if provider.nil? || provider.empty?

        s = stat(provider)
        amount = row['amount'].to_i
        status = row['status']
        s.count += 1
        s.volume += amount
        s.latency_by_status[status] << row['latency_sec'].to_i
        case status
        when 'approved' then s.approved_count += 1
        when 'rejected' then s.rejected_count += 1
        when 'expired' then s.expired_count += 1
        end
      end
    end
  end
end
