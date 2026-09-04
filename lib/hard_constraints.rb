# frozen_string_literal: true

module RoutingEngine
  # Hard-constraints — условия допуска провайдера к роутингу заявки.
  # Отвечают на вопрос "можно ли вообще отправить эту заявку этому провайдеру?".
  # Нарушение хотя бы одного — провайдер исключается независимо от стратегии
  # (soft-goals из strategy_scorer.rb сюда не подмешиваются).
  module HardConstraints
    Result = Struct.new(:eligible, :reason, :details, keyword_init: true)

    CHECKS = [
      lambda do |p, _op|
        p.status == 'active' ? nil : ['provider_inactive', "status=#{p.status}"]
      end,
      lambda do |p, op|
        next ['amount_below_minimum', "#{op.amount} < limit_amount_min #{p.limit_amount_min}"] if p.limit_amount_min && op.amount < p.limit_amount_min
        next ['amount_exceeds_limit', "#{op.amount} > limit_amount_max #{p.limit_amount_max}"] if p.limit_amount_max && op.amount > p.limit_amount_max

        nil
      end,
      lambda do |p, op|
        next nil unless p.daily_amount_limit

        projected = p.daily_approved_amount.to_f + op.amount
        projected > p.daily_amount_limit ? ['daily_limit_exceeded', "#{projected.to_i} > daily_amount_limit #{p.daily_amount_limit}"] : nil
      end,
      lambda do |p, _op|
        next nil unless p.in_progress_count_limit

        projected = p.in_progress_count.to_i + 1
        projected > p.in_progress_count_limit ? ['in_progress_count_limit_exceeded', "#{projected} > #{p.in_progress_count_limit}"] : nil
      end,
      lambda do |p, op|
        next nil unless p.in_progress_amount_limit

        projected = p.in_progress_amount.to_f + op.amount
        projected > p.in_progress_amount_limit ? ['in_progress_amount_limit_exceeded', "#{projected.to_i} > #{p.in_progress_amount_limit}"] : nil
      end,
      lambda do |p, _op|
        p.available_requisites.to_i.zero? ? ['no_available_requisites', 'available_requisites=0'] : nil
      end,
      lambda do |p, _op|
        next nil if p.allow_negative_agreement
        next nil if p.provider_margin_pct.to_f <= p.merchant_margin_pct.to_f

        ['margin_exceeds_agreement', "provider_margin #{p.provider_margin_pct} > merchant_margin #{p.merchant_margin_pct}"]
      end,
      lambda do |p, op|
        banks = p.banks || []
        next nil if banks.empty?

        in_list = banks.include?(op.bank)
        allowed = p.exclude_banks ? !in_list : in_list
        allowed ? nil : ['bank_not_in_list', "bank=#{op.bank}"]
      end,
      lambda do |p, op|
        next nil unless p.requests_per_minute_limit

        count = p.requests_in_last_minute(op.created_at)
        count >= p.requests_per_minute_limit ? ['rate_limit_exceeded', "#{count}/min >= limit #{p.requests_per_minute_limit}"] : nil
      end
    ].freeze

    def self.evaluate(provider, operation)
      CHECKS.each do |check|
        failure = check.call(provider, operation)
        next unless failure

        reason, details = failure
        return Result.new(eligible: false, reason: reason, details: details)
      end
      Result.new(eligible: true, reason: nil, details: nil)
    end
  end
end
