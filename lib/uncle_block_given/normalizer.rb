# frozen_string_literal: true

module UncleBlockGiven
  # Converts raw JSON-RPC objects (blocks, transactions, receipts, logs) into
  # Ruby-friendly hashes: snake_case symbol keys, QUANTITY fields as Integers.
  module Normalizer
    module_function

    QUANTITY_KEYS = %i[
      number timestamp gas_used gas_limit base_fee_per_gas block_number transaction_index log_index
      cumulative_gas_used effective_gas_price status value gas gas_price max_fee_per_gas
      max_priority_fee_per_gas chain_id type difficulty total_difficulty size nonce blob_gas_used
      blob_gas_price excess_blob_gas max_fee_per_blob_gas l1_fee l1_gas_used l1_gas_price l1_fee_scalar
      deposit_nonce deposit_receipt_version
    ].freeze

    def normalize(value)
      case value
      when Hash then value.each_with_object({}) do |(k, v), h|
        h[key = Utils.snake_case(k).to_sym] = normalize_field(key, v)
      end
      when Array then value.map { |v| normalize(v) }
      else value
      end
    end

    def normalize_field(key, value)
      if QUANTITY_KEYS.include?(key) && Utils.hex?(value)
        value == "0x" ? nil : Utils.hex_to_int(value)
      elsif key == :topics && value.is_a?(Array)
        value
      else
        normalize(value)
      end
    end
  end
end
