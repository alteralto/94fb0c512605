# frozen_string_literal: true

module RoutingEngine
  # Аналитика качества роутинга: факт vs цель по долям, причины skip,
  # загрузка дневных лимитов и рекомендации по правкам конфигурации.
  class ReportBuilder
    SIGNIFICANT_SHARE_DRIFT_PCT = 10
    HIGH_UTILIZATION_PCT = 80

    def initialize(pool:, decisions:, period:)
      @pool = pool
      @decisions = decisions
      @period = period
    end

    def build
      {
        'period' => @period,
        'total_operations' => @decisions.size,
        'distribution' => distribution,
        'skip_reasons' => skip_reasons,
        'projected_daily_utilization' => utilization,
        'recommendations' => recommendations
      }
    end

    private

    def distribution
      by_provider = @decisions.group_by { |d| d['selected_provider'] }
      total = @decisions.size

      @pool.all.to_h do |p|
        count = by_provider.fetch(p.payment_system, []).size
        share = total.zero? ? 0.0 : (count.to_f / total * 100).round(1)
        [p.payment_system, { 'count' => count, 'share_pct' => share, 'target_pct' => p.traffic_percentage.to_f }]
      end
    end

    def skip_reasons
      counts = Hash.new(0)
      @decisions.each do |d|
        d['attempts'].each { |a| counts[a['reason']] += 1 if a['decision'] == 'skipped' }
      end
      counts
    end

    def utilization
      @pool.all.filter_map do |p|
        next unless p.daily_amount_limit

        used = p.daily_approved_amount.to_f
        [p.payment_system, {
          'used' => used.to_i,
          'limit' => p.daily_amount_limit,
          'utilization_pct' => (used / p.daily_amount_limit * 100).round(1)
        }]
      end.to_h
    end

    def recommendations
      recs = share_drift_recommendations + utilization_recommendations
      recs << 'существенных отклонений не обнаружено' if recs.empty?
      recs
    end

    def share_drift_recommendations
      distribution.filter_map do |name, d|
        next if d['target_pct'].zero?

        diff = (d['share_pct'] - d['target_pct']).round(1)
        if diff > SIGNIFICANT_SHARE_DRIFT_PCT
          "#{name}: факт #{d['share_pct']}% против цели #{d['target_pct']}% — снизить приоритет/traffic_percentage в конфиге"
        elsif diff < -SIGNIFICANT_SHARE_DRIFT_PCT
          "#{name}: факт #{d['share_pct']}% против цели #{d['target_pct']}% — заявок недостаточно, повысить приоритет"
        end
      end
    end

    def utilization_recommendations
      utilization.filter_map do |name, u|
        next unless u['utilization_pct'] >= HIGH_UTILIZATION_PCT

        "#{name}: использовано #{u['utilization_pct']}% дневного лимита — риск исчерпания, готовить fallback/пересмотреть daily_amount_limit"
      end
    end
  end
end
