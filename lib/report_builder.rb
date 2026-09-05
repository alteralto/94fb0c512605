# frozen_string_literal: true

module RoutingEngine
  # Аналитика качества роутинга: факт vs цель по долям, успешность и отказы,
  # причины skip, загрузка дневных лимитов и рекомендации по правкам конфигурации.
  #
  # Рекомендации намеренно называют конкретный параметр конфига, который надо
  # подвинуть, а не ограничиваются констатацией отклонения.
  class ReportBuilder
    SIGNIFICANT_SHARE_DRIFT_PCT = 10
    HIGH_UTILIZATION_PCT = 80
    # Ниже этой выборки история слишком шумная, чтобы спорить с декларацией провайдера.
    MIN_CONVERSION_SAMPLE = 10
    CONVERSION_GAP_ALERT_PCT = 15

    # Причины, по которым провайдер отсеян жёстким ограничением (а не проиграл скоринг).
    # Нужны, чтобы объяснить недобор доли: "не выбирался" и "не мог быть выбран" —
    # разные диагнозы и разные лечения.
    # Коды здесь обязаны совпадать с теми, что возвращает HardConstraints::CHECKS —
    # рассинхрон молча ломает объяснение недобора, поэтому он проверяется тестом
    # test/routing_test.rb (test_blocking_reasons_cover_all_hard_constraints).
    REASON_LABEL = {
      'provider_inactive' => 'провайдер неактивен',
      'amount_below_minimum' => 'сумма заявки ниже его минимума',
      'amount_exceeds_limit' => 'сумма заявки выше его лимита',
      'daily_limit_exceeded' => 'исчерпан дневной лимит',
      'in_progress_count_limit_exceeded' => 'упёрся в лимит одновременных заявок',
      'in_progress_amount_limit_exceeded' => 'упёрся в лимит суммы in-progress',
      'no_available_requisites' => 'нет свободных реквизитов',
      'margin_exceeds_agreement' => 'маржа хуже соглашения',
      'bank_not_in_list' => 'банк заявки не обслуживается',
      'rate_limit_exceeded' => 'превышен лимит заявок в минуту'
    }.freeze

    # Причины, по которым провайдер отсеян жёстким ограничением (а не проиграл скоринг).
    # Нужны, чтобы объяснить недобор доли: "не выбирался" и "не мог быть выбран" —
    # разные диагнозы и разные лечения.
    BLOCKING_REASONS = REASON_LABEL.keys.freeze

    def initialize(pool:, decisions:, period:, operations: [])
      @pool = pool
      @decisions = decisions
      @period = period
      # Суммы заявок нужны, чтобы посчитать стоимость распределения; сам список
      # решений сумм не содержит, поэтому очередь передаётся отдельно.
      @amounts = (operations || []).to_h { |op| [op.operation_id, op.amount] }
    end

    def build
      {
        'period' => @period,
        'total_operations' => @decisions.size,
        'distribution' => distribution,
        'results' => results,
        'cost' => cost,
        'provider_quality' => provider_quality,
        'skip_reasons' => skip_reasons,
        'projected_daily_utilization' => utilization,
        'recommendations' => recommendations
      }
    end

    private

    def distribution
      @distribution ||= begin
        by_provider = @decisions.group_by { |d| d['selected_provider'] }
        total = @decisions.size

        @pool.all.to_h do |p|
          count = by_provider.fetch(p.payment_system, []).size
          share = total.zero? ? 0.0 : (count.to_f / total * 100).round(1)
          # target_pct — как записано в providers.json; effective_target_pct — то же
          # после перераспределения долей недоступных провайдеров. Показываем обе:
          # первая объясняет замысел, вторая — то, с чем реально сверяется роутер.
          [p.payment_system, { 'count' => count, 'share_pct' => share,
                               'target_pct' => p.traffic_percentage.to_f,
                               'effective_target_pct' => p.effective_traffic_pct.to_f }]
        end
      end
    end

    # Успешность прогона целиком: сколько заявок реально дошло до approved.
    def results
      counts = Hash.new(0)
      @decisions.each { |d| counts[d['simulated_result']] += 1 }
      total = @decisions.size
      {
        'approved' => counts['approved'],
        'rejected' => counts['rejected'],
        'expired' => counts['expired'],
        'success_rate_pct' => total.zero? ? 0.0 : (counts['approved'].to_f / total * 100).round(1)
      }
    end

    # Во что обошлось распределение. Комиссия платится за проведённые операции,
    # поэтому считаем по approved. Справочный минимум — если бы весь этот объём
    # взял самый дешёвый внешний провайдер; он почти всегда недостижим (лимиты,
    # банки, доли), но показывает цену компромиссов в рублях, а не в процентах.
    def cost
      return {} if @amounts.empty?

      approved = @decisions.select { |d| d['simulated_result'] == 'approved' }
      volume = approved.sum { |d| @amounts.fetch(d['operation_id'], 0).to_f }
      return {} if volume.zero?

      fee = approved.sum do |d|
        amount = @amounts.fetch(d['operation_id'], 0).to_f
        rate = @pool.find(d['selected_provider'])&.provider_margin_pct.to_f
        amount * rate / 100.0
      end

      cheapest = @pool.all.reject(&:self_provider?).map { |p| p.provider_margin_pct.to_f }.min.to_f
      floor = volume * cheapest / 100.0
      {
        'approved_volume' => volume.round,
        'provider_fee' => fee.round,
        'effective_rate_pct' => (fee / volume * 100).round(3),
        'cheapest_rate_pct' => cheapest,
        'fee_at_cheapest' => floor.round,
        'overpay_vs_cheapest' => (fee - floor).round
      }
    end

    # Разрез по провайдерам: сколько заявок увёл, сколько провёл, сколько раз
    # отказал или не ответил уже после выбора, средняя задержка.
    def provider_quality
      @provider_quality ||= @pool.all.to_h do |p|
        name = p.payment_system
        mine = @decisions.select { |d| d['selected_provider'] == name }
        approved = mine.count { |d| d['simulated_result'] == 'approved' }
        latencies = mine.filter_map { |d| d['latency_sec'] }
        [name, {
          'selected' => mine.size,
          'approved' => approved,
          'success_rate_pct' => mine.empty? ? 0.0 : (approved.to_f / mine.size * 100).round(1),
          'declined' => attempts_with(name, 'provider_declined_processing'),
          'timeouts' => attempts_with(name, 'provider_timeout_unknown_status'),
          'avg_latency_sec' => latencies.empty? ? 0 : (latencies.sum.to_f / latencies.size).round,
          'conversion_declared_pct' => (p.declared_conversion_24h.to_f * 100).round(1),
          'conversion_observed_pct' => p.observed_conversion_24h.nil? ? nil : (p.observed_conversion_24h * 100).round(1),
          'conversion_used_pct' => (p.conversion_24h.to_f * 100).round(1),
          'history_sample' => p.observed_sample.to_i
        }]
      end
    end

    def attempts_with(provider_name, reason)
      @decisions.sum do |d|
        d['attempts'].count { |a| a['provider'] == provider_name && a['reason'] == reason }
      end
    end

    def skip_reasons
      counts = Hash.new(0)
      @decisions.each do |d|
        d['attempts'].each { |a| counts[a['reason']] += 1 if a['decision'] == 'skipped' }
      end
      counts
    end

    # Сколько раз конкретного провайдера отсекало жёсткое ограничение и какое именно.
    def blocking_reasons_for(provider_name)
      counts = Hash.new(0)
      @decisions.each do |d|
        d['attempts'].each do |a|
          next unless a['provider'] == provider_name && BLOCKING_REASONS.include?(a['reason'])

          counts[a['reason']] += 1
        end
      end
      counts
    end

    # 1 раз, 2-4 раза, 5+ раз — отчёт читают люди.
    def times_word(count)
      tail = count % 100
      return 'раз' if (11..14).cover?(tail)

      case count % 10
      when 1 then 'раз'
      when 2, 3, 4 then 'раза'
      else 'раз'
      end
    end

    def utilization
      @utilization ||= @pool.all.filter_map do |p|
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
      recs = unavailable_provider_recommendations + unreachable_goal_recommendations +
             conversion_mismatch_recommendations +
             share_drift_recommendations + utilization_recommendations + quality_recommendations
      recs << 'существенных отклонений не обнаружено' if recs.empty?
      recs
    end

    # Провайдер заявляет в providers.json одну конверсию, а история показывает
    # другую. Это не повод молча выбрать одну из цифр — это повод сказать вслух,
    # потому что расхождение может означать и подмену периода, и реальную
    # деградацию провайдера.
    def conversion_mismatch_recommendations
      @pool.all.filter_map do |p|
        observed = p.observed_conversion_24h
        declared = p.declared_conversion_24h
        next if observed.nil? || declared.nil? || p.observed_sample.to_i < MIN_CONVERSION_SAMPLE

        gap_pct = ((observed - declared) * 100).round(1)
        next if gap_pct.abs < CONVERSION_GAP_ALERT_PCT

        "#{p.payment_system}: заявленная конверсия #{(declared * 100).round(1)}%, а по истории " \
          "#{(observed * 100).round(1)}% на #{p.observed_sample} операциях (#{gap_pct} п.п.) — " \
          "в скоринге используется сглаженная оценка #{(p.conversion_24h * 100).round(1)}%; " \
          'сверить период выгрузки, при подтверждении пересматривать долю провайдера'
      end
    end

    # Прямой ответ на ситуацию "нужная доля назначена недоступному провайдеру":
    # роутер не может её закрыть в принципе, поэтому доля перераспределяется между
    # оставшимися, а отчёт называет провайдера, причину и величину перераспределения.
    def unavailable_provider_recommendations
      @pool.unreachable_targets.map do |t|
        receivers = @pool.all.reject { |p| p.self_provider? || p.structurally_unavailable? }
                         .map { |p| "#{p.payment_system} #{p.effective_traffic_pct}%" }.join(', ')
        [
          "#{t['provider']}: целевая доля #{t['target_pct']}% недостижима — #{t['reason']};",
          "доля перераспределена между доступными (#{receivers}).",
          'Роутер сверяется с effective_target_pct; чтобы вернуть провайдера в план,',
          'снимать надо причину недоступности, а не веса'
        ].join(' ')
      end
    end

    # Цель, невыполнимая по конструкции конфига: обязательство по обороту больше
    # дневного лимита того же провайдера. Такую цель роутер не закроет никогда,
    # сколько трафика в него ни направляй — правится это только в конфиге.
    def unreachable_goal_recommendations
      @pool.all.filter_map do |p|
        min = p.daily_turnover_min.to_f
        limit = p.daily_amount_limit.to_f
        next unless min.positive? && limit.positive? && min > limit

        "#{p.payment_system}: обязательство daily_turnover_min #{min.to_i} ₽ выше дневного лимита " \
          "#{limit.to_i} ₽ — цель недостижима при любом распределении, снизить daily_turnover_min " \
          'или поднять daily_amount_limit'
      end
    end

    # Отклонение считается от ЭФФЕКТИВНОЙ цели: сверяться с исходной, когда часть
    # пула недоступна, значит ругать доступных провайдеров за чужую невыполнимую долю.
    # Недоступный провайдер сюда не попадает вовсе — про него говорит
    # unavailable_provider_recommendations, и дублировать диагноз незачем.
    def share_drift_recommendations
      distribution.filter_map do |name, d|
        target = d['effective_target_pct']
        next if target.zero?

        diff = (d['share_pct'] - target).round(1)
        next unless diff.abs > SIGNIFICANT_SHARE_DRIFT_PCT

        goal = (target - d['target_pct']).abs < 0.05 ? "цели #{target}%" : "эффективной цели #{target}% (в providers.json #{d['target_pct']}%)"
        if diff.positive?
          "#{name}: факт #{d['share_pct']}% против #{goal} — снизить traffic_percentage " \
            'или вес count_share_gap в конфиге'
        else
          "#{name}: факт #{d['share_pct']}% против #{goal}#{drift_cause(name)}"
        end
      end
    end

    # Недобор доли объясняем причиной, а не общими словами: если провайдера
    # отсекали жёсткие ограничения — повышать ему приоритет бессмысленно,
    # менять надо сами ограничения.
    def drift_cause(name)
      blocking = blocking_reasons_for(name)
      return ' — заявок недостаточно, повысить вес count_share_gap' if blocking.empty?

      reason, times = blocking.max_by { |_, v| v }
      [
        " — недобор не из-за стратегии: #{times} #{times_word(times)} отсечён жёстким",
        "ограничением (#{REASON_LABEL.fetch(reason, reason)}), правка веса тут не поможет"
      ].join(' ')
    end

    # Совет "готовить fallback" осмыслен только для провайдера, который в
    # принципе берёт заявки: у выключенного загрузка — это просто застывший
    # входной снапшот, и предупреждать о ней незачем.
    def utilization_recommendations
      utilization.filter_map do |name, u|
        next unless u['utilization_pct'] >= HIGH_UTILIZATION_PCT
        next if @pool.find(name)&.structurally_unavailable?

        "#{name}: использовано #{u['utilization_pct']}% дневного лимита — риск исчерпания, " \
          'готовить fallback/пересмотреть daily_amount_limit'
      end
    end

    # Провайдер, который берёт заявки, но заметно чаще прочих отказывает или
    # не отвечает, — повод снизить ему долю, а не только смотреть на конверсию.
    def quality_recommendations
      provider_quality.filter_map do |name, q|
        failures = q['declined'] + q['timeouts']
        next unless failures >= 2

        "#{name}: #{failures} отказов/таймаутов на этапе приёма заявки — проверить провайдера, " \
          'при повторении снизить traffic_percentage'
      end
    end
  end
end
