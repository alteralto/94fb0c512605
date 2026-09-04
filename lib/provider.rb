# frozen_string_literal: true

module RoutingEngine
  # Провайдер с изменяемым состоянием, которое обновляется по мере
  # обработки очереди заявок ("Обновление метрик" из hard-constraints ТЗ).
  class Provider
    RAW_ATTRS = %i[payment_system status traffic_percentage priority limit_amount_min
                   limit_amount_max daily_amount_limit daily_approved_amount
                   in_progress_count_limit in_progress_count in_progress_amount_limit
                   in_progress_amount available_requisites conversion_24h avg_latency_sec
                   banks exclude_banks provider_margin_pct merchant_margin_pct
                   allow_negative_agreement].freeze

    attr_accessor(*RAW_ATTRS)
    # Поля, которых нет в providers.json — заполняются ProviderPool
    # из config/strategy.yml (бизнес-параметры) и operations_history.csv (доля объёма).
    attr_accessor :volume_share_pct, :requests_per_minute_limit, :daily_turnover_min
    # Признак self-provider ставит ProviderPool по self_provider_name из конфига
    # (не хардкод "spacepayments" — при смене имени в тестовых данных ничего не сломается).
    attr_writer :self_provider
    # Живое состояние в рамках текущего прогона роутинга. routed_count/routed_volume
    # считают только УСПЕШНЫЕ (approved) операции — это то, что сверяется с
    # traffic_percentage/volume_share_pct, см. StrategyScorer.
    attr_accessor :routed_count, :routed_volume
    attr_reader :recent_attempt_times

    def initialize(raw)
      RAW_ATTRS.each { |a| send("#{a}=", raw[a.to_s]) }
      @banks ||= []
      @self_provider = false
      @routed_count = 0
      @routed_volume = 0
      @recent_attempt_times = []
    end

    def self_provider?
      @self_provider
    end

    def register_attempt(operation)
      @recent_attempt_times << operation.created_at
    end

    def requests_in_last_minute(as_of)
      @recent_attempt_times.count { |t| as_of - t < 60 }
    end

    # Резервирует мощность провайдера в момент выбора — до того как известен исход.
    # in_progress/available_requisites отражают заявки, которые СЕЙЧАС обрабатываются,
    # а не только успешные — поэтому резервируются сразу.
    def reserve!(operation)
      self.in_progress_count = in_progress_count.to_i + 1
      self.in_progress_amount = in_progress_amount.to_f + operation.amount
      self.available_requisites = [available_requisites.to_i - 1, 0].max unless self_provider?
    end

    # Освобождает резерв после того, как известен итог (approved/rejected/expired —
    # во всех трёх случаях обработка завершена, канал/реквизит освобождается).
    # daily_approved_amount и квоты доли (routed_count/routed_volume) растут ТОЛЬКО
    # при approved — недобор доли не должен закрываться попытками, которые не прошли.
    def resolve!(operation, result)
      self.in_progress_count = [in_progress_count.to_i - 1, 0].max
      self.in_progress_amount = [in_progress_amount.to_f - operation.amount, 0].max
      self.available_requisites = available_requisites.to_i + 1 unless self_provider?
      return unless result == 'approved'

      self.daily_approved_amount = daily_approved_amount.to_f + operation.amount
      @routed_count += 1
      @routed_volume += operation.amount
    end
  end
end
