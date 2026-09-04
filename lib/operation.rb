# frozen_string_literal: true

require 'time'

module RoutingEngine
  class Operation
    attr_reader :operation_id, :created_at, :amount, :bank, :raw

    def initialize(raw)
      @raw = raw
      @operation_id = raw.fetch('operation_id')
      @created_at = Time.iso8601(raw.fetch('created_at'))
      @amount = raw.fetch('amount').to_i
      @bank = raw['bank']
    end
  end
end
