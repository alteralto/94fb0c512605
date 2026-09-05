# frozen_string_literal: true

# Тесты движка роутинга: ruby test/routing_test.rb
# Только стандартная библиотека (minitest идёт в поставке Ruby), без гемов.

require 'minitest/autorun'
require 'json'
require 'time'

ROOT = File.expand_path('..', __dir__)
%w[config_loader history_stats provider provider_pool operation hard_constraints
   strategy_scorer simulator router report_builder pipeline].each do |f|
  require File.join(ROOT, 'lib', f)
end

module Fixtures
  module_function

  # Минимальный провайдер: всё разрешено, чтобы каждый тест ломал ровно одно условие.
  def provider(overrides = {})
    raw = {
      'payment_system' => 'testpay', 'status' => 'active', 'traffic_percentage' => 50,
      'priority' => 1, 'limit_amount_min' => 100, 'limit_amount_max' => 100_000,
      'daily_amount_limit' => 1_000_000, 'daily_approved_amount' => 0,
      'in_progress_count_limit' => 10, 'in_progress_count' => 0,
      'in_progress_amount_limit' => 500_000, 'in_progress_amount' => 0,
      'available_requisites' => 5, 'conversion_24h' => 0.9, 'avg_latency_sec' => 30,
      'banks' => [], 'exclude_banks' => false,
      'provider_margin_pct' => 1.0, 'merchant_margin_pct' => 1.5
    }.merge(overrides)
    RoutingEngine::Provider.new(raw)
  end

  def operation(overrides = {})
    RoutingEngine::Operation.new({
      'operation_id' => 'op_test', 'created_at' => '2026-07-30T09:05:00+03:00',
      'amount' => 10_000, 'bank' => 'sberbank'
    }.merge(overrides))
  end

  def history
    @history ||= RoutingEngine::HistoryStats.new(File.join(ROOT, 'data', 'operations_history.csv'))
  end

  def providers_json
    JSON.parse(File.read(File.join(ROOT, 'data', 'providers.json')))
  end

  def config
    RoutingEngine::ConfigLoader.load(File.join(ROOT, 'config', 'strategy.yml'))
  end

  def queue
    JSON.parse(File.read(File.join(ROOT, 'data', 'operations_queue_10.json')))
  end
end

class HardConstraintsTest < Minitest::Test
  def assert_blocked(reason, provider, operation = Fixtures.operation)
    res = RoutingEngine::HardConstraints.evaluate(provider, operation)
    refute res.eligible, "ожидали блокировку по #{reason}, провайдер прошёл"
    assert_equal reason, res.reason
    refute_nil res.details, 'details обязателен: по нему эксперт понимает, почему отсекли'
  end

  def test_clean_provider_is_eligible
    assert RoutingEngine::HardConstraints.evaluate(Fixtures.provider, Fixtures.operation).eligible
  end

  def test_inactive_provider_blocked
    assert_blocked 'provider_inactive', Fixtures.provider('status' => 'disabled')
  end

  def test_amount_below_minimum_blocked
    assert_blocked 'amount_below_minimum', Fixtures.provider, Fixtures.operation('amount' => 50)
  end

  def test_amount_above_maximum_blocked
    assert_blocked 'amount_exceeds_limit', Fixtures.provider, Fixtures.operation('amount' => 200_000)
  end

  # Дневной лимит проверяется по ПРОГНОЗУ (текущий оборот + сумма заявки),
  # а не по факту постфактум.
  def test_daily_limit_checked_against_projection
    p = Fixtures.provider('daily_approved_amount' => 995_000)
    assert_blocked 'daily_limit_exceeded', p, Fixtures.operation('amount' => 10_000)
    assert RoutingEngine::HardConstraints.evaluate(p, Fixtures.operation('amount' => 4_000)).eligible
  end

  def test_in_progress_count_limit_blocked
    assert_blocked 'in_progress_count_limit_exceeded', Fixtures.provider('in_progress_count' => 10)
  end

  def test_in_progress_amount_limit_blocked
    assert_blocked 'in_progress_amount_limit_exceeded', Fixtures.provider('in_progress_amount' => 495_000)
  end

  def test_no_requisites_blocked
    assert_blocked 'no_available_requisites', Fixtures.provider('available_requisites' => 0)
  end

  def test_margin_worse_than_agreement_blocked
    assert_blocked 'margin_exceeds_agreement', Fixtures.provider('provider_margin_pct' => 2.0)
  end

  # allow_negative_agreement — явное согласие работать в минус по марже.
  def test_margin_allowed_when_agreement_permits
    p = Fixtures.provider('provider_margin_pct' => 2.0, 'allow_negative_agreement' => true)
    assert RoutingEngine::HardConstraints.evaluate(p, Fixtures.operation).eligible
  end

  def test_bank_not_in_allow_list_blocked
    assert_blocked 'bank_not_in_list', Fixtures.provider('banks' => %w[alfa vtb])
  end

  # Тот же список с exclude_banks=true работает наоборот: перечисленные запрещены.
  def test_bank_list_inverted_by_exclude_flag
    p = Fixtures.provider('banks' => %w[sberbank], 'exclude_banks' => true)
    assert_blocked 'bank_not_in_list', p
    assert RoutingEngine::HardConstraints.evaluate(p, Fixtures.operation('bank' => 'alfa')).eligible
  end

  def test_empty_bank_list_allows_any_bank
    p = Fixtures.provider('banks' => [])
    assert RoutingEngine::HardConstraints.evaluate(p, Fixtures.operation('bank' => 'exotic')).eligible
  end

  def test_rate_limit_counts_attempts_within_minute
    p = Fixtures.provider
    p.requests_per_minute_limit = 2
    op = Fixtures.operation
    2.times { p.register_attempt(op) }
    assert_blocked 'rate_limit_exceeded', p, op
  end
end

class ProviderStateTest < Minitest::Test
  # Реквизит занимается на время обработки и обязан вернуться после исхода —
  # иначе на длинной очереди провайдер необратимо уходит в ноль реквизитов.
  def test_requisite_reserved_and_released
    p = Fixtures.provider('available_requisites' => 1)
    op = Fixtures.operation
    p.reserve!(op)
    assert_equal 0, p.available_requisites
    p.resolve!(op, 'rejected')
    assert_equal 1, p.available_requisites
    assert_equal 0, p.in_progress_count
  end

  # Квота доли закрывается только успешной операцией: неуспешная попытка
  # не должна засчитываться провайдеру как выполненная доля.
  def test_quota_grows_only_on_approved
    p = Fixtures.provider
    op = Fixtures.operation('amount' => 5_000)

    p.reserve!(op)
    p.resolve!(op, 'expired')
    assert_equal 0, p.routed_count
    assert_equal 0, p.daily_approved_amount.to_f

    p.reserve!(op)
    p.resolve!(op, 'approved')
    assert_equal 1, p.routed_count
    assert_equal 5_000.0, p.daily_approved_amount.to_f
    assert_equal 5_000.0, p.routed_volume.to_f
  end

  def test_self_provider_does_not_consume_requisites
    p = Fixtures.provider('available_requisites' => 1)
    p.self_provider = true
    p.reserve!(Fixtures.operation)
    assert_equal 1, p.available_requisites, 'self-provider не должен тратить чужие реквизиты'
  end
end

class StrategyScorerTest < Minitest::Test
  def scorer(weights)
    providers = [@lagging, @leading]
    RoutingEngine::StrategyScorer.new(weights: weights, amount_bands: [], providers: providers)
  end

  def setup
    @lagging = Fixtures.provider('payment_system' => 'lagging', 'traffic_percentage' => 50)
    @leading = Fixtures.provider('payment_system' => 'leading', 'traffic_percentage' => 50)
    @lagging.routed_count = 0
    @leading.routed_count = 10
  end

  # Ключевая механика стратегии 1: кто отстал от целевой доли, тот получает приоритет.
  def test_provider_behind_target_scores_higher
    s = scorer('count_share_gap' => 1.0)
    behind, = s.score(@lagging, Fixtures.operation)
    ahead, = s.score(@leading, Fixtures.operation)
    assert behind > ahead, "отстающий #{behind} должен обходить перебравшего #{ahead}"
  end

  # Веса — единственный способ смешивать факторы; нулевой вес обязан
  # полностью выключать фактор, иначе конфиг врёт.
  def test_zero_weight_disables_factor
    s = scorer('count_share_gap' => 0.0)
    assert_in_delta s.score(@lagging, Fixtures.operation).first,
                    s.score(@leading, Fixtures.operation).first, 1e-9
  end

  def test_amount_band_bonus_applies_to_preferred_provider
    bands = [{ 'max_amount' => 50_000, 'prefer' => 'lagging' }]
    s = RoutingEngine::StrategyScorer.new(weights: { 'amount_band' => 1.0 }, amount_bands: bands,
                                          providers: [@lagging, @leading])
    preferred, = s.score(@lagging, Fixtures.operation('amount' => 10_000))
    other, = s.score(@leading, Fixtures.operation('amount' => 10_000))
    assert preferred > other
  end

  def test_factors_are_exposed_for_explanation
    _, factors = scorer('count_share_gap' => 1.0).score(@lagging, Fixtures.operation)
    RoutingEngine::StrategyScorer::FACTORS.each_key do |name|
      assert factors.key?(name), "фактор #{name} обязан попадать в объяснение"
      %w[value weight contribution label].each do |field|
        assert factors[name].key?(field), "у фактора #{name} нет поля #{field}"
      end
    end
  end

  # Объяснение обязано показывать ВКЛАД (значение x вес), иначе по логу
  # нельзя понять, что именно перевесило.
  def test_contribution_is_value_times_weight
    _, factors = scorer('count_share_gap' => 1.0, 'conversion' => 0.5).score(@lagging, Fixtures.operation)
    factors.each do |name, f|
      assert_in_delta f['value'] * f['weight'], f['contribution'], 1e-3, "вклад #{name} не сходится"
    end
  end

  # Каждый вес в боевом конфиге обязан иметь фактор в реестре: опечатка в
  # имени иначе молча выключает целое правило распределения.
  def test_every_configured_weight_has_a_factor
    unknown = Fixtures.config['weights'].keys.map(&:to_s) - RoutingEngine::StrategyScorer::FACTORS.keys
    assert_empty unknown, 'в config/strategy.yml есть веса без фактора в реестре'
  end
end

# Стратегия 6: текущая загрузка влияет на ВЫБОР, а не только на допуск.
class LoadPressureTest < Minitest::Test
  def scorer(providers, threshold_pct = 80)
    RoutingEngine::StrategyScorer.new(weights: { 'load_headroom' => 1.0 }, amount_bands: [],
                                      providers: providers, load: { 'pressure_threshold_pct' => threshold_pct })
  end

  def test_load_below_threshold_is_not_penalised
    calm = Fixtures.provider('daily_approved_amount' => 100_000, 'daily_amount_limit' => 1_000_000)
    assert_in_delta 1.0, scorer([calm]).load_headroom(calm, Fixtures.operation), 1e-9
  end

  def test_load_above_threshold_is_penalised_proportionally
    # 900_000 + 10_000 из 1_000_000 = 91% при пороге 80% -> съедено 55% интервала.
    hot = Fixtures.provider('daily_approved_amount' => 900_000, 'daily_amount_limit' => 1_000_000)
    assert_in_delta 0.45, scorer([hot]).load_headroom(hot, Fixtures.operation), 1e-6
  end

  def test_provider_at_the_limit_gets_zero_headroom
    full = Fixtures.provider('daily_approved_amount' => 990_000, 'daily_amount_limit' => 1_000_000)
    assert_in_delta 0.0, scorer([full]).load_headroom(full, Fixtures.operation), 1e-9
  end

  # Самый узкий лимит определяет загрузку: дневной может быть свободен,
  # а число одновременных заявок — уже нет.
  def test_tightest_axis_wins
    p = Fixtures.provider('daily_approved_amount' => 0, 'in_progress_count' => 9,
                          'in_progress_count_limit' => 10)
    assert_in_delta 0.0, scorer([p]).load_headroom(p, Fixtures.operation), 1e-9
  end

  def test_provider_without_limits_is_never_penalised
    free = Fixtures.provider('daily_amount_limit' => nil, 'in_progress_count_limit' => nil,
                             'in_progress_amount_limit' => nil)
    assert_in_delta 1.0, scorer([free]).load_headroom(free, Fixtures.operation), 1e-9
  end

  # Ради чего фактор и заведён: при прочих равных перегруженный проигрывает свободному.
  def test_overloaded_provider_scores_lower_than_free_one
    hot = Fixtures.provider('payment_system' => 'hot', 'daily_approved_amount' => 950_000)
    free = Fixtures.provider('payment_system' => 'free', 'daily_approved_amount' => 0)
    s = scorer([hot, free])
    assert s.score(free, Fixtures.operation).first > s.score(hot, Fixtures.operation).first
  end
end

# Поведение, когда целевая доля назначена провайдеру, которому нельзя
# отдать ни одной заявки.
class UnavailableTargetTest < Minitest::Test
  def pool_with(status_overrides)
    json = Fixtures.providers_json
    json['providers'].each do |p|
      over = status_overrides[p['payment_system']]
      p.merge!(over) if over
    end
    RoutingEngine::ProviderPool.new(providers_json: json, overrides: {}, history: Fixtures.history,
                                    self_provider_name: 'spacepayments', conversion: {})
  end

  def test_unavailable_provider_target_is_redistributed
    pool = pool_with('payflow' => { 'status' => 'disabled' })
    assert_in_delta 0.0, pool.find('payflow').effective_traffic_pct, 1e-9
    live = pool.all.reject { |p| p.self_provider? || p.payment_system == 'payflow' }
    assert_in_delta 100.0, live.sum(&:effective_traffic_pct), 0.05,
                    'доли доступных обязаны снова складываться в 100%'
    assert pool.find('vipay').effective_traffic_pct > pool.find('vipay').traffic_percentage,
           'освободившаяся доля должна достаться оставшимся'
  end

  def test_zero_requisites_makes_provider_unavailable
    pool = pool_with('vipay' => { 'available_requisites' => 0 })
    assert_in_delta 0.0, pool.find('vipay').effective_traffic_pct, 1e-9
  end

  def test_exhausted_daily_limit_makes_provider_unavailable
    pool = pool_with('quickpay' => { 'daily_approved_amount' => 8_000_000 })
    refute_nil pool.find('quickpay').unavailable_reason
    assert_in_delta 0.0, pool.find('quickpay').effective_traffic_pct, 1e-9
  end

  def test_report_names_provider_reason_and_redistribution
    pool = pool_with('payflow' => { 'status' => 'disabled' })
    report = RoutingEngine::ReportBuilder.new(pool: pool, decisions: [], period: nil).build
    line = report['recommendations'].find { |r| r.start_with?('payflow:') }
    refute_nil line, 'отчёт обязан назвать недоступного провайдера с невыполнимой целью'
    assert_includes line, 'недостижима'
    assert_includes line, 'status=disabled'
  end

  def test_all_targets_survive_when_everyone_is_available
    pool = pool_with({})
    %w[vipay payflow quickpay].each do |name|
      p = pool.find(name)
      assert_in_delta p.traffic_percentage, p.effective_traffic_pct, 0.05,
                      'без недоступных цели не должны съезжать'
    end
    assert_empty pool.unreachable_targets
  end
end

class ConversionBlendTest < Minitest::Test
  def pool(prior)
    RoutingEngine::ProviderPool.new(
      providers_json: Fixtures.providers_json, overrides: {}, history: Fixtures.history,
      self_provider_name: 'spacepayments', conversion: { 'prior_strength' => prior }
    )
  end

  # payflow заявляет 0.91, а в истории проводит 9 из 19 (0.474).
  def test_blend_sits_between_declared_and_observed
    p = pool(10).find('payflow')
    assert_in_delta 0.91, p.declared_conversion_24h, 1e-6
    assert_in_delta 0.474, p.observed_conversion_24h, 0.001
    assert p.conversion_24h < p.declared_conversion_24h
    assert p.conversion_24h > p.observed_conversion_24h
  end

  def test_zero_prior_trusts_history_only
    p = pool(0).find('payflow')
    assert_in_delta p.observed_conversion_24h, p.conversion_24h, 0.001
  end

  def test_huge_prior_trusts_declaration_only
    p = pool(10_000_000).find('payflow')
    assert_in_delta p.declared_conversion_24h, p.conversion_24h, 0.001
  end

  # Провайдера может не быть в истории — тогда спорить с декларацией нечем.
  def test_provider_absent_from_history_keeps_declaration
    p = pool(10).find('spacepayments')
    assert_nil p.observed_conversion_24h
    assert_in_delta p.declared_conversion_24h, p.conversion_24h, 1e-6
  end
end

class ProviderPoolTest < Minitest::Test
  def test_self_provider_resolved_from_config_name
    pool = RoutingEngine::ProviderPool.new(
      providers_json: Fixtures.providers_json, overrides: {}, history: Fixtures.history,
      self_provider_name: 'quickpay'
    )
    assert_equal 'quickpay', pool.self_provider.payment_system,
                 'self-provider обязан браться из конфига, а не быть захардкоженным'
  end

  # Любой параметр провайдера переопределяется конфигом — на этом держится
  # требование "менять параметры без правки кода".
  def test_any_provider_field_can_be_overridden
    pool = RoutingEngine::ProviderPool.new(
      providers_json: Fixtures.providers_json,
      overrides: { 'vipay' => { 'daily_amount_limit' => 42, 'daily_turnover_min' => 7 } },
      history: Fixtures.history, self_provider_name: 'spacepayments'
    )
    assert_equal 42, pool.find('vipay').daily_amount_limit
    assert_equal 7, pool.find('vipay').daily_turnover_min
  end

  def test_unknown_override_key_is_ignored_not_fatal
    _, err = capture_io do
      RoutingEngine::ProviderPool.new(
        providers_json: Fixtures.providers_json, overrides: { 'vipay' => { 'no_such_field' => 1 } },
        history: Fixtures.history, self_provider_name: 'spacepayments'
      )
    end
    assert_match(/no_such_field/, err)
  end
end

class RouterCascadeTest < Minitest::Test
  # Симулятор с заданным сценарием исходов — чтобы проверять каскад, а не удачу сида.
  class ScriptedSimulator
    def initialize(outcomes) = @outcomes = outcomes.dup
    def pre_attempt_outcome(provider) = @outcomes.fetch(provider.payment_system, :accepted)
    def final_result(_provider) = 'approved'
    def latency_sec(_provider, _result) = 10
  end

  def pool
    RoutingEngine::ProviderPool.new(
      providers_json: Fixtures.providers_json, overrides: {}, history: Fixtures.history,
      self_provider_name: 'spacepayments'
    )
  end

  def route(outcomes, operation = Fixtures.operation('amount' => 15_000, 'bank' => 'sberbank'))
    RoutingEngine::Router.new(
      pool: pool, scorer_weights: Fixtures.config['weights'],
      amount_bands: Fixtures.config['amount_bands'], simulator: ScriptedSimulator.new(outcomes)
    ).route(operation)
  end

  def test_declined_provider_is_skipped_and_next_one_takes_over
    d = route('vipay' => :declined, 'payflow' => :declined)
    assert_equal 'quickpay', d['selected_provider']
    reasons = d['attempts'].map { |a| a['reason'] }
    assert_includes reasons, 'provider_declined_processing'
  end

  # Таймаут — не то же самое, что отказ: статус выплаты неизвестен, и в объяснении
  # обязан быть след идемпотентной проверки перед уходом к следующему провайдеру.
  def test_timeout_is_distinguished_from_decline
    d = route('vipay' => :timeout, 'payflow' => :timeout, 'quickpay' => :timeout)
    timeout_attempts = d['attempts'].select { |a| a['reason'] == 'provider_timeout_unknown_status' }
    refute_empty timeout_attempts
    assert_match(/идемпотентн/i, timeout_attempts.first['details'])
  end

  def test_falls_back_to_self_provider_when_pool_exhausted
    d = route('vipay' => :declined, 'payflow' => :declined, 'quickpay' => :timeout)
    assert_equal 'spacepayments', d['selected_provider']
    assert_equal 'fallback_self_provider', d['attempts'].last['reason']
  end

  # Объяснимость: у каждой попытки есть провайдер, решение и причина,
  # и ровно одна попытка помечена selected.
  def test_every_attempt_is_explained
    d = route({})
    assert_equal 1, d['attempts'].count { |a| a['decision'] == 'selected' }
    d['attempts'].each do |a|
      %w[provider decision reason].each { |k| refute_nil a[k], "в попытке нет поля #{k}" }
      assert_includes %w[selected skipped], a['decision']
    end
  end
end

class SimulatorTest < Minitest::Test
  def sim(seed: 1, rate: 0.5)
    RoutingEngine::Simulator.new(seed: seed, decline_base_rate: rate, history: Fixtures.history)
  end

  def outcomes(simulator, times = 300)
    provider = Fixtures.provider('payment_system' => 'vipay', 'conversion_24h' => 0.8)
    Array.new(times) { simulator.pre_attempt_outcome(provider) }
  end

  # Кейс требует различать "отказал" и "не ответил" — симулятор обязан
  # порождать оба исхода, иначе ветка таймаута в роутере мертва.
  def test_produces_both_declines_and_timeouts
    seen = outcomes(sim).tally
    assert seen[:declined].to_i.positive?, "не встретился явный отказ: #{seen}"
    assert seen[:timeout].to_i.positive?, "не встретился таймаут: #{seen}"
    assert seen[:accepted].to_i.positive?, "не встретился приём заявки: #{seen}"
  end

  def test_self_provider_always_accepts
    provider = Fixtures.provider
    provider.self_provider = true
    s = sim(rate: 1.0)
    assert(Array.new(50) { s.pre_attempt_outcome(provider) }.all?(:accepted),
           'self-provider — последний рубеж, он не может отказать')
  end

  # Воспроизводимость: одинаковый seed обязан давать одинаковую последовательность.
  def test_same_seed_reproduces_sequence
    assert_equal outcomes(sim(seed: 42), 50), outcomes(sim(seed: 42), 50)
    refute_equal outcomes(sim(seed: 42), 50), outcomes(sim(seed: 43), 50)
  end

  def test_zero_decline_rate_with_perfect_conversion_never_declines
    provider = Fixtures.provider('conversion_24h' => 1.0)
    s = sim(rate: 0.0)
    assert(Array.new(50) { s.pre_attempt_outcome(provider) }.all?(:accepted))
  end

  def test_final_result_is_always_a_valid_status
    s = sim
    provider = Fixtures.provider('payment_system' => 'vipay')
    Array.new(100) { s.final_result(provider) }.each do |r|
      assert_includes %w[approved rejected expired], r
    end
  end
end

class ReportBuilderTest < Minitest::Test
  def pool(overrides = {})
    RoutingEngine::ProviderPool.new(
      providers_json: Fixtures.providers_json, overrides: overrides, history: Fixtures.history,
      self_provider_name: 'spacepayments', conversion: { 'prior_strength' => 10 }
    )
  end

  def build(pool, decisions)
    RoutingEngine::ReportBuilder.new(pool: pool, decisions: decisions, period: '2026-07-30').build
  end

  def decision(provider, result = 'approved', attempts = nil)
    { 'operation_id' => "op_#{rand(1000)}", 'selected_provider' => provider,
      'attempts' => attempts || [{ 'provider' => provider, 'decision' => 'selected', 'reason' => 'top_ranked_by_strategy' }],
      'simulated_result' => result, 'latency_sec' => 20 }
  end

  # Коды причин в отчёте обязаны совпадать с тем, что реально отдаёт HardConstraints:
  # рассинхрон молча ломает объяснение недобора доли (и однажды уже ломал).
  # Каждый кейс ниже нарушает РОВНО одно ограничение у во всём остальном чистого
  # провайдера, поэтому evaluate вернёт именно ожидаемую причину.
  def test_blocking_reasons_cover_all_hard_constraints
    rate_limited = Fixtures.provider
    rate_limited.requests_per_minute_limit = 1
    rate_limited.register_attempt(Fixtures.operation)

    cases = [
      [Fixtures.provider('status' => 'disabled'), Fixtures.operation],
      [Fixtures.provider, Fixtures.operation('amount' => 1)],
      [Fixtures.provider, Fixtures.operation('amount' => 10_000_000)],
      [Fixtures.provider('daily_approved_amount' => 999_999), Fixtures.operation],
      [Fixtures.provider('in_progress_count' => 99), Fixtures.operation],
      [Fixtures.provider('in_progress_amount' => 499_999), Fixtures.operation],
      [Fixtures.provider('available_requisites' => 0), Fixtures.operation],
      [Fixtures.provider('provider_margin_pct' => 9.0), Fixtures.operation],
      [Fixtures.provider('banks' => %w[nothing]), Fixtures.operation],
      [rate_limited, Fixtures.operation]
    ]

    produced = cases.map do |provider, operation|
      res = RoutingEngine::HardConstraints.evaluate(provider, operation)
      refute res.eligible, 'кейс должен был заблокировать провайдера, но он прошёл'
      res.reason
    end.uniq

    documented = RoutingEngine::ReportBuilder::BLOCKING_REASONS
    assert_empty(produced - documented, 'движок отдаёт причины, не описанные в отчёте')
    assert_empty(documented - produced, 'в отчёте описаны причины, которых движок не отдаёт')
    assert_equal RoutingEngine::HardConstraints::CHECKS.size + 1, produced.size,
                 'на каждую hard-проверку должен приходиться кейс (диапазон суммы даёт две причины)'
  end

  def test_unreachable_turnover_goal_is_reported
    report = build(pool('payflow' => { 'daily_turnover_min' => 5_000_000 }), [decision('payflow')])
    assert(report['recommendations'].any? { |r| r.include?('недостижима') },
           "не поймана невыполнимая цель: #{report['recommendations']}")
  end

  # Недобор из-за жёсткого ограничения нельзя лечить весами — отчёт обязан это сказать.
  def test_drift_caused_by_hard_constraint_is_named
    blocked = [{ 'provider' => 'vipay', 'decision' => 'skipped', 'reason' => 'bank_not_in_list', 'details' => 'bank=x' },
               { 'provider' => 'quickpay', 'decision' => 'selected', 'reason' => 'top_ranked_by_strategy' }]
    decisions = Array.new(4) { decision('quickpay', 'approved', blocked) }
    report = build(pool, decisions)
    vipay_rec = report['recommendations'].find { |r| r.start_with?('vipay:') }
    assert vipay_rec, "нет вывода про vipay: #{report['recommendations']}"
    assert_match(/жёстким ограничением/, vipay_rec)
  end

  def test_conversion_mismatch_is_reported
    report = build(pool, [decision('payflow')])
    assert(report['recommendations'].any? { |r| r.include?('заявленная конверсия') },
           "не поймано расхождение конверсии: #{report['recommendations']}")
  end

  def test_results_block_counts_outcomes
    report = build(pool, [decision('vipay', 'approved'), decision('vipay', 'rejected')])
    assert_equal 1, report['results']['approved']
    assert_equal 1, report['results']['rejected']
    assert_in_delta 50.0, report['results']['success_rate_pct'], 0.01
  end
end

class PipelineTest < Minitest::Test
  def run_pipeline(override = {})
    config = RoutingEngine::Pipeline.deep_merge(Fixtures.config, override)
    RoutingEngine::Pipeline.new(config: config, providers_json: Fixtures.providers_json,
                                history: Fixtures.history, queue_raw: Fixtures.queue).run
  end

  def test_deep_merge_keeps_base_when_override_is_nil
    merged = RoutingEngine::Pipeline.deep_merge({ 'a' => { 'b' => 1, 'c' => 2 } }, { 'a' => { 'b' => nil } })
    assert_equal 1, merged['a']['b']
    assert_equal 2, merged['a']['c']
  end

  def test_deep_merge_is_recursive
    merged = RoutingEngine::Pipeline.deep_merge({ 'w' => { 'x' => 1, 'y' => 2 } }, { 'w' => { 'y' => 9 } })
    assert_equal({ 'x' => 1, 'y' => 9 }, merged['w'])
  end

  # Один и тот же seed обязан давать побайтово тот же результат — иначе
  # перепроверка организаторами не воспроизведёт наш routing_decisions_test.json.
  def test_same_seed_gives_identical_output
    a = run_pipeline('simulation' => { 'seed' => 777 })
    b = run_pipeline('simulation' => { 'seed' => 777 })
    assert_equal JSON.generate(a.decisions), JSON.generate(b.decisions)
  end

  def test_different_seed_changes_simulation_outcome
    a = run_pipeline('simulation' => { 'seed' => 1, 'provider_decline_base_rate' => 0.5 })
    b = run_pipeline('simulation' => { 'seed' => 2, 'provider_decline_base_rate' => 0.5 })
    refute_equal JSON.generate(a.decisions), JSON.generate(b.decisions)
  end

  def test_every_queued_operation_gets_a_decision
    result = run_pipeline
    assert_equal Fixtures.queue.size, result.decisions.size
    assert_equal Fixtures.queue.map { |q| q['operation_id'] }, result.decisions.map { |d| d['operation_id'] }
  end

  # Схема сдачи: без этих полей файл не примут независимо от качества роутинга.
  def test_decisions_match_required_schema
    run_pipeline.decisions.each do |d|
      %w[operation_id selected_provider attempts simulated_result latency_sec].each do |key|
        refute_nil d[key], "в решении нет обязательного поля #{key}"
      end
      assert_includes %w[approved rejected expired], d['simulated_result']
      refute_empty d['attempts']
    end
  end

  def test_empty_queue_produces_empty_result_not_crash
    config = Fixtures.config
    result = RoutingEngine::Pipeline.new(config: config, providers_json: Fixtures.providers_json,
                                         history: Fixtures.history, queue_raw: []).run
    assert_empty result.decisions
    assert_equal 0, result.report['total_operations']
  end

  # Заявка, которую не берёт ни один внешний провайдер, обязана уйти на self-provider,
  # а не потеряться.
  def test_operation_nobody_can_take_goes_to_self_provider
    result = RoutingEngine::Pipeline.new(
      config: Fixtures.config, providers_json: Fixtures.providers_json, history: Fixtures.history,
      queue_raw: [{ 'operation_id' => 'op_weird', 'created_at' => '2026-07-30T09:05:00+03:00',
                    'amount' => 999_999_999, 'bank' => 'unknown_bank' }]
    ).run
    assert_equal 'spacepayments', result.decisions.first['selected_provider']
  end
end
