# frozen_string_literal: true

module BlockGiven
  # Serialization, signing and decoding of the two transaction types the gem sends: EIP-1559 (type 2) and
  # legacy (type 0) with EIP-155 replay protection.
  #
  # Parameters use the shape of {Wallet#prepare_transaction} (`:to`, `:value`, `:data`, `:chain_id`, `:nonce`,
  # `:gas`, `:access_list`, plus `:gas_price` for legacy or the two EIP-1559 fee fields).
  #
  # Access lists are given and returned as `[{ address: "0x...", storage_keys: ["0x..."] }]`; the RLP form
  # `[["0x...", ["0x..."]]]` and camelCase or String keys (`storageKeys`) are accepted as input too.
  #
  # @api private
  module TransactionEnvelope
    # EIP-2718 type byte of EIP-1559 transactions.
    TYPE_EIP1559 = 2

    module_function

    # Signs a transaction.
    #
    # @param params [Hash{Symbol => Object}] resolved parameters ({Wallet#prepare_transaction}); `:gas_price`
    #   selects a legacy transaction
    # @param private_key [Integer] the signing key
    # @return [String] the signed transaction bytes as `0x` hex
    # @raise [BlockGiven::InvalidArgumentError] when a field is negative or the gas limit is below the
    #   intrinsic gas of the transaction
    def sign(params, private_key)
      Fields.validate!(params)
      if params[:gas_price]
        sign_legacy(params, private_key)
      else
        sign_eip1559(params, private_key)
      end
    end

    # Decodes signed transaction bytes and recovers the sender.
    #
    # @param raw [String] the signed transaction as hex, with or without `0x`
    # @return [Hash{Symbol => Object}] the {Wallet#prepare_transaction} shape (`:from` checksummed, `:to` nil
    #   for a contract creation, `:data` `""` when empty, `:access_list` nil when empty)
    # @raise [BlockGiven::InvalidArgumentError] for malformed bytes, an unsupported transaction type or a
    #   signature that recovers no key
    def decode(raw)
      hex = Utils.strip_hex(raw.to_s)
      raise InvalidArgumentError, "not an even-length hex string" unless hex.match?(/\A(?:[0-9a-fA-F]{2})*\z/)

      bytes = Utils.hex_to_bin(hex)
      first = bytes.getbyte(0)
      raise InvalidArgumentError, "empty transaction" if first.nil?
      return decode_eip1559(bytes.byteslice(1..)) if first == TYPE_EIP1559
      return decode_legacy(bytes) if first >= 0xc0

      raise InvalidArgumentError, "unsupported transaction type #{first}"
    end

    # Signs an EIP-1559 transaction.
    #
    # @param params [Hash{Symbol => Object}]
    # @param private_key [Integer]
    # @return [String] `0x02...` hex
    def sign_eip1559(params, private_key)
      fields = [
        params[:chain_id], params[:nonce], params[:max_priority_fee_per_gas], params[:max_fee_per_gas],
        params[:gas], address_bytes(params[:to]), params[:value], Utils.hex_to_bin(params[:data].to_s),
        Fields.rlp_access_list(params[:access_list])
      ]
      r, s, recovery_id = Crypto::Secp256k1.sign(Crypto::Keccak.digest(typed(fields)), private_key)
      Utils.bin_to_hex(typed(fields + [recovery_id, r, s]))
    end

    # Signs a legacy transaction with EIP-155 replay protection (`v = recovery_id + 35 + 2 * chain_id`).
    #
    # @param params [Hash{Symbol => Object}]
    # @param private_key [Integer]
    # @return [String] RLP list hex
    def sign_legacy(params, private_key)
      fields = [
        params[:nonce], params[:gas_price], params[:gas], address_bytes(params[:to]), params[:value],
        Utils.hex_to_bin(params[:data].to_s)
      ]
      chain_id = params[:chain_id]
      r, s, recovery_id = Crypto::Secp256k1.sign(Crypto::Keccak.digest(Rlp.encode(fields + [chain_id, 0, 0])),
                                                 private_key)
      Utils.bin_to_hex(Rlp.encode(fields + [recovery_id + 35 + (2 * chain_id), r, s]))
    end

    # Decodes the RLP payload of an EIP-1559 transaction (type byte removed).
    #
    # @param payload [String] binary
    # @return [Hash{Symbol => Object}]
    # @raise [BlockGiven::InvalidArgumentError] when the payload is not a 12-field list
    def decode_eip1559(payload)
      fields = Rlp.decode(payload)
      unless fields.is_a?(Array) && fields.size == 12
        raise InvalidArgumentError,
              "EIP-1559 transaction must have 12 fields"
      end

      chain_id, nonce, priority, max_fee, gas, = fields.first(5).map { |f| Rlp.to_int(f) }
      y_parity, r, s = fields.last(3).map { |f| Rlp.to_int(f) }
      raise InvalidArgumentError, "invalid y parity #{y_parity}" if y_parity > 1

      sender = recover_address(typed(fields.first(9)), r, s, y_parity)
      access_list = Fields.parse_access_list(fields[8])
      common_params(sender, fields[5], fields[6], fields[7]).merge(
        chain_id: chain_id, nonce: nonce, gas: gas, max_fee_per_gas: max_fee, max_priority_fee_per_gas: priority,
        access_list: access_list.empty? ? nil : access_list
      )
    end

    # Decodes a legacy transaction, with (EIP-155) or without replay protection.
    #
    # @param bytes [String] binary RLP list
    # @return [Hash{Symbol => Object}] `:chain_id` is nil for a transaction signed without replay protection
    # @raise [BlockGiven::InvalidArgumentError] when the list does not have 9 fields or `v` is invalid
    def decode_legacy(bytes)
      fields = Rlp.decode(bytes)
      raise InvalidArgumentError, "legacy transaction must have 9 fields" unless fields.is_a?(Array) && fields.size == 9

      nonce, gas_price, gas = fields.first(3).map { |f| Rlp.to_int(f) }
      v, r, s = fields.last(3).map { |f| Rlp.to_int(f) }
      chain_id, recovery_id, unsigned = legacy_signing_payload(fields.first(6), v)
      sender = recover_address(Rlp.encode(unsigned), r, s, recovery_id)
      common_params(sender, fields[3], fields[4], fields[5]).merge(
        chain_id: chain_id, nonce: nonce, gas: gas, gas_price: gas_price, access_list: nil
      )
    end

    # The chain id, recovery id and unsigned field list of a legacy transaction, from its `v`.
    #
    # @param fields [Array<String>] the six unsigned fields
    # @param v [Integer]
    # @return [Array(Integer, Integer, Array)] chain id (nil for `v` 27 or 28), recovery id, fields to hash
    # @raise [BlockGiven::InvalidArgumentError] when `v` is neither 27, 28 nor an EIP-155 value
    def legacy_signing_payload(fields, v)
      return [nil, v - 27, fields] if [27, 28].include?(v)
      raise InvalidArgumentError, "invalid legacy signature v #{v}" if v < 37

      chain_id = (v - 35) / 2
      [chain_id, (v - 35) % 2, fields + [chain_id, 0, 0]]
    end

    # Fields both transaction types share, formatted.
    #
    # @param sender [String] checksummed sender
    # @param to [String] binary destination (empty for a creation)
    # @param value [String] binary amount
    # @param data [String] binary calldata
    # @return [Hash{Symbol => Object}]
    # @raise [BlockGiven::InvalidArgumentError] when `to` is neither empty nor 20 bytes
    def common_params(sender, to, value, data)
      raise InvalidArgumentError, "invalid destination" unless to.is_a?(String) && [0, 20].include?(to.bytesize)
      raise InvalidArgumentError, "invalid data field" unless data.is_a?(String)

      {
        from: sender, to: to.empty? ? nil : Utils.checksum_address(Utils.bin_to_hex(to)),
        value: Rlp.to_int(value), data: data.empty? ? "" : Utils.bin_to_hex(data)
      }
    end

    # Recovers the checksummed address that signed a payload.
    #
    # @param payload [String] the unsigned serialization, binary
    # @param r [Integer]
    # @param s [Integer]
    # @param recovery_id [Integer]
    # @return [String] the checksummed address
    # @raise [BlockGiven::InvalidArgumentError] when no key can be recovered
    def recover_address(payload, r, s, recovery_id)
      public_key = Crypto::Secp256k1.recover(Crypto::Keccak.digest(payload), r, s, recovery_id)
      Crypto.address(public_key)
    end

    # @param fields [Array] RLP items
    # @return [String] the type-2 envelope: `0x02` followed by the RLP list, binary
    def typed(fields) = TYPE_EIP1559.chr.b + Rlp.encode(fields)

    # @param address [String, nil] hex address or nil for a contract creation
    # @return [String] 20 binary bytes, or an empty String
    def address_bytes(address) = address.nil? ? "".b : Utils.hex_to_bin(address)
  end
end
