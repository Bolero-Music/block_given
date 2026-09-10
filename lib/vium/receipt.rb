# frozen_string_literal: true

module Vium
  # Transaction receipt with symbolized, integer-decoded fields.
  class Receipt
    attr_reader :to_h

    def initialize(raw)
      @to_h = raw.is_a?(Receipt) ? raw.to_h : Normalizer.normalize(raw)
    end

    def transaction_hash = to_h[:transaction_hash]
    def block_number = to_h[:block_number]
    def block_hash = to_h[:block_hash]
    def from = to_h[:from]
    def to = to_h[:to]
    def contract_address = to_h[:contract_address]
    def gas_used = to_h[:gas_used]
    def effective_gas_price = to_h[:effective_gas_price]
    def cumulative_gas_used = to_h[:cumulative_gas_used]
    def transaction_index = to_h[:transaction_index]
    def logs = to_h[:logs] || []

    # :success / :reverted (pre-Byzantium receipts have no status: treated as success).
    def status
      return :success if to_h[:status].nil?

      to_h[:status] == 1 ? :success : :reverted
    end

    def success? = status == :success
    def reverted? = status == :reverted

    # Total fee paid in wei.
    def fee = gas_used && effective_gas_price ? gas_used * effective_gas_price : nil

    def [](key) = to_h[key.to_sym]

    def inspect
      "#<Vium::Receipt #{transaction_hash} status=#{status} block=#{block_number} " \
        "gas_used=#{gas_used} logs=#{logs.size}>"
    end
  end
end
