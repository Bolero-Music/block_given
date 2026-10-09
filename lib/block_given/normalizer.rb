# frozen_string_literal: true

module BlockGiven
  # Convert raw JSON-RPC objects (blocks, transactions, receipts, logs) into Ruby-friendly hashes.
  #
  # Keys become snake_case symbols (`"blockNumber"` -> `:block_number`) and the fields listed in
  # {QUANTITY_KEYS} are decoded from hex QUANTITY strings to Integers. Nested hashes and arrays are normalised
  # recursively, except a log's `topics`, which stay an Array of `0x` hex strings. Addresses, hashes and `data`
  # fields are left exactly as the node returned them. {Client} runs every block, transaction, receipt and log
  # through this module before handing it back.
  #
  # @example
  #   BlockGiven::Normalizer.normalize({ "blockNumber" => "0x10", "logIndex" => "0x0", "topics" => ["0xddf2"] })
  #   # => { block_number: 16, log_index: 0, topics: ["0xddf2"] }
  module Normalizer
    module_function

    # Snake_case keys whose values are JSON-RPC QUANTITY hex strings, decoded to Integers by {.normalize}.
    #
    # Covers block, transaction and receipt fields, EIP-4844 blob fields, and the L1 fee fields added by
    # OP Stack chains (Base, Optimism).
    QUANTITY_KEYS = %i[
      number timestamp gas_used gas_limit base_fee_per_gas block_number transaction_index log_index
      cumulative_gas_used effective_gas_price status value gas gas_price max_fee_per_gas
      max_priority_fee_per_gas chain_id type difficulty total_difficulty size nonce blob_gas_used
      blob_gas_price excess_blob_gas max_fee_per_blob_gas l1_fee l1_gas_used l1_gas_price l1_fee_scalar
      deposit_nonce deposit_receipt_version
    ].freeze

    # Normalise a raw RPC value recursively.
    #
    # @param value [Hash, Array, Object] a Hash is rebuilt with snake_case Symbol keys and normalised values,
    #   an Array is mapped element by element, anything else is returned untouched
    # @return [Hash{Symbol => Object}, Array, Object]
    def normalize(value)
      case value
      when Hash then value.each_with_object({}) do |(k, v), h|
        h[key = Utils.snake_case(k).to_sym] = normalize_field(key, v)
      end
      when Array then value.map { |v| normalize(v) }
      else value
      end
    end

    # Normalise one field of an RPC hash, given its already snake_cased key.
    #
    # @api private
    # @param key [Symbol] snake_case key
    # @param value [Object] raw value
    # @return [Object] an Integer for a {QUANTITY_KEYS} key holding hex (nil when the node returned an empty
    #   `"0x"`), the untouched Array for `:topics`, otherwise {.normalize} of the value
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
