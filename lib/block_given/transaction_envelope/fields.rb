# frozen_string_literal: true

module BlockGiven
  module TransactionEnvelope
    # Field-level rules shared by signing and decoding: access list conversion, sanity checks and the intrinsic
    # gas a transaction must cover.
    #
    # @api private
    module Fields
      # Base cost of any transaction.
      BASE_GAS = 21_000
      # Extra cost of a contract creation.
      CREATE_GAS = 32_000
      # Calldata cost of a zero byte.
      ZERO_BYTE_GAS = 4
      # Calldata cost of a non-zero byte.
      NON_ZERO_BYTE_GAS = 16
      # Cost of each 32-byte word of init code (EIP-3860).
      INITCODE_WORD_GAS = 2
      # Cost of each address of an access list (EIP-2930).
      ACCESS_LIST_ADDRESS_GAS = 2_400
      # Cost of each storage key of an access list (EIP-2930).
      ACCESS_LIST_KEY_GAS = 1_900

      module_function

      # Converts an access list into its RLP form.
      #
      # @param list [Array<Hash, Array>, nil] in one of the forms {TransactionEnvelope} accepts
      # @return [Array<Array>] `[[address_bytes, [key_bytes...]]...]`
      # @raise [BlockGiven::InvalidArgumentError] for an entry that is neither a Hash nor a pair
      def rlp_access_list(list)
        Array(list).map do |entry|
          address, keys =
            case entry
            when Hash
              entry = entry.transform_keys { |k| Utils.snake_case(k) }
              [entry["address"], entry["storage_keys"]]
            when Array then entry
            else raise InvalidArgumentError, "invalid access list entry #{entry.inspect}"
            end
          [Utils.hex_to_bin(address.to_s), Array(keys).map { |key| Utils.hex_to_bin(Utils.pad_hex(key)) }]
        end
      end

      # Converts a decoded RLP access list into Ruby values.
      #
      # @param list [Array] decoded RLP items
      # @return [Array<Hash{Symbol => Object}>] `[{ address:, storage_keys: }]`
      # @raise [BlockGiven::InvalidArgumentError] when the structure is not an access list
      def parse_access_list(list)
        raise InvalidArgumentError, "invalid access list" unless list.is_a?(Array)

        list.map do |entry|
          valid = entry.is_a?(Array) && entry.size == 2 && entry[0].is_a?(String) && entry[1].is_a?(Array)
          raise InvalidArgumentError, "invalid access list" unless valid

          { address: Utils.checksum_address(Utils.bin_to_hex(entry[0])),
            storage_keys: entry[1].map { |key| Utils.bin_to_hex(key) } }
        end
      end

      # Rejects parameters no node would accept.
      #
      # @param params [Hash{Symbol => Object}]
      # @return [void]
      # @raise [BlockGiven::InvalidArgumentError] for a negative or missing field, a chain id below 1 or a gas
      #   limit under the intrinsic gas
      def validate!(params)
        fee_fields = params[:gas_price] ? %i[gas_price] : %i[max_fee_per_gas max_priority_fee_per_gas]
        (%i[nonce gas value] + fee_fields).each do |field|
          value = params[field]
          next if value.is_a?(Integer) && !value.negative?

          raise InvalidArgumentError, "invalid #{field}: #{value.inspect}"
        end
        chain_id = params[:chain_id]
        unless chain_id.is_a?(Integer) && chain_id.positive?
          raise InvalidArgumentError, "invalid chain_id: #{chain_id.inspect}"
        end

        minimum = intrinsic_gas(params)
        return if params[:gas] >= minimum

        raise InvalidArgumentError,
              "gas limit #{params[:gas]} is below the intrinsic gas of the transaction (#{minimum})"
      end

      # Minimum gas a transaction pays before executing anything.
      #
      # @param params [Hash{Symbol => Object}]
      # @return [Integer]
      def intrinsic_gas(params)
        data = Utils.hex_to_bin(params[:data].to_s)
        zeros = data.count("\x00")
        gas = BASE_GAS + (zeros * ZERO_BYTE_GAS) + ((data.bytesize - zeros) * NON_ZERO_BYTE_GAS)
        gas += CREATE_GAS + (INITCODE_WORD_GAS * ((data.bytesize + 31) / 32)) if params[:to].nil?
        gas + rlp_access_list(params[:access_list]).sum do |entry|
          ACCESS_LIST_ADDRESS_GAS + (ACCESS_LIST_KEY_GAS * entry[1].size)
        end
      end
    end
  end
end
