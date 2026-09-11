# frozen_string_literal: true

module BlockGiven
  # A signed transaction that has not been broadcast yet.
  #
  # The transaction hash is the keccak-256 of the signed RLP bytes, so {#hash} and {#nonce} are known before
  # any network call: persist them (or {#raw} / {#to_h}), then {#broadcast}. Whatever happens to the RPC call,
  # the transaction can be found again with `client.transaction(hash)` or {#transaction}.
  #
  # Lifecycle:
  #
  # 1. {Wallet#signed_transaction} (or `Contract#prepare_write`) signs and returns an instance.
  # 2. {#broadcast} sends the bytes with `eth_sendRawTransaction` and returns a {Transaction} carrying the local
  #    hash (a warning is logged if the node answers with a different hash).
  # 3. If the transaction is stuck in the mempool, {#replacement} re-signs the same payload with the same nonce
  #    and higher fees; only one of the two can ever be mined.
  # 4. After a restart, {.from_raw} rebuilds an instance from the persisted bytes so steps 2 and 3 still work.
  #
  # `hash` is the transaction hash (a String, like {Transaction#hash}), not Ruby's Object#hash: instances are
  # not usable as Hash keys or Set members; compare them with {#==}.
  #
  # @example Sign, persist, broadcast, then replace when stuck
  #   signed = registry.prepare_write(:record, movement_id, tx: { nonce: call.nonce })
  #   call.update!(tx_hash: signed.hash, nonce: signed.nonce, raw_tx: signed.raw, status: :submitted)
  #   tx = signed.broadcast                            # => BlockGiven::Transaction (same hash)
  #
  #   signed.replacement.broadcast if tx.pending?      # same nonce, fees bumped by 12.5%
  class SignedTransaction
    # Nodes reject a same-nonce replacement whose fees are not at least 10% higher than the original's.
    MIN_REPLACEMENT_MULTIPLIER = 1.1
    # Fee multiplier used by {#replacement} when none is given (12.5% bump, geth's default replacement rule).
    DEFAULT_REPLACEMENT_MULTIPLIER = 1.125

    # Rebuilds a signed transaction from persisted raw bytes, typically after a process restart, so it can be
    # broadcast again ({#broadcast}) or replaced ({#replacement}).
    #
    # The bytes are decoded with `Eth::Tx.decode`; both EIP-1559 (type 2) and legacy (type 0) transactions are
    # supported and the recovered sender must be `wallet`'s address, since only that wallet can sign a
    # replacement.
    #
    # @param raw [String] the signed transaction bytes as hex (with or without `0x`), as returned by {#raw}
    # @param wallet [Wallet] the wallet that signed the bytes; used by {#replacement} to re-sign
    # @param interface [Abi::Interface, nil] ABI used to decode custom errors when the node rejects the
    #   broadcast with revert data (typically `contract.interface`)
    # @return [SignedTransaction] the rebuilt transaction; its {#params} mirror {Wallet#prepare_transaction}
    # @raise [BlockGiven::InvalidArgumentError] when the bytes cannot be decoded, or when they were signed by
    #   another address than `wallet.address`
    # @example
    #   signed = BlockGiven::SignedTransaction.from_raw(payout.raw_tx, wallet: wallet, interface: usdc.interface)
    #   signed.hash == payout.tx_hash # => true
    #   signed.transaction.status     # => :pending
    def self.from_raw(raw, wallet:, interface: nil)
      decoded = begin
        Eth::Tx.decode(Utils.prefix_hex(raw))
      rescue StandardError => e
        raise InvalidArgumentError, "cannot decode signed transaction: #{e.message}"
      end
      sender = Utils.checksum_address(Utils.prefix_hex(decoded.sender)) # eth returns unprefixed hex
      unless Utils.same_address?(sender, wallet.address)
        raise InvalidArgumentError, "signed transaction was sent by #{sender}, not by wallet #{wallet.address}"
      end

      new(raw: raw, params: params_from(decoded, sender), wallet: wallet, interface: interface)
    end

    def self.params_from(decoded, sender)
      destination = decoded.destination.to_s
      params = {
        from: sender, to: destination.empty? ? nil : Utils.checksum_address(Utils.prefix_hex(destination)),
        value: decoded.amount, data: decoded.payload.to_s.empty? ? "" : Utils.bin_to_hex(decoded.payload),
        chain_id: decoded.chain_id, nonce: decoded.signer_nonce, gas: decoded.gas_limit
      }
      # Same shape as Wallet#prepare_transaction (access_list nil when empty).
      if decoded.respond_to?(:max_fee_per_gas)
        access_list = decoded.access_list
        params.merge(max_fee_per_gas: decoded.max_fee_per_gas,
                     max_priority_fee_per_gas: decoded.max_priority_fee_per_gas,
                     access_list: access_list.nil? || access_list.empty? ? nil : access_list)
      else
        params.merge(gas_price: decoded.gas_price, access_list: nil)
      end
    end
    private_class_method :params_from

    # @!attribute [r] raw
    #   @return [String] the RLP-encoded signed transaction as `0x`-prefixed hex, as sent to
    #     `eth_sendRawTransaction`
    # @!attribute [r] hash
    #   @return [String] the transaction hash (`0x` hex, keccak-256 of {#raw}), identical to the hash the node
    #     will report once broadcast. A String, so this is not Ruby's Object#hash
    # @!attribute [r] params
    #   @return [Hash{Symbol => Object}] the frozen resolved parameters the bytes were signed from, in the shape
    #     returned by {Wallet#prepare_transaction} (`:from`, `:to`, `:value`, `:data`, `:chain_id`, `:nonce`,
    #     `:gas`, `:access_list`, plus `:gas_price` or the two EIP-1559 fee fields)
    # @!attribute [r] wallet
    #   @return [Wallet] the wallet that signed the bytes and that {#replacement} re-signs with
    # @!attribute [r] interface
    #   @return [Abi::Interface, nil] ABI used to name custom errors on revert, or nil
    attr_reader :raw, :hash, :params, :wallet, :interface

    # Wraps already signed bytes. Applications normally get instances from {Wallet#signed_transaction},
    # `Contract#prepare_write` or {.from_raw} rather than calling this directly.
    #
    # @param raw [String] the signed transaction bytes as hex (with or without `0x`)
    # @param params [Hash{Symbol => Object}] the resolved parameters the bytes were signed from (frozen here)
    # @param wallet [Wallet] the signing wallet
    # @param interface [Abi::Interface, nil] ABI used to name custom errors when the node rejects the
    #   broadcast with revert data (set by `Contract#prepare_write`)
    def initialize(raw:, params:, wallet:, interface: nil)
      @raw = Utils.prefix_hex(raw)
      @params = params.freeze
      @wallet = wallet
      @interface = interface
      @hash = Utils.keccak256(@raw)
    end

    # Returns a copy of this signed transaction that decodes custom errors with the given ABI.
    #
    # @param interface [Abi::Interface, nil] the ABI to use for revert decoding
    # @return [SignedTransaction] a new instance with the same bytes, params and wallet
    def with_interface(interface) = self.class.new(raw: raw, params: params, wallet: wallet, interface: interface)

    # The client used to broadcast and to look the transaction up.
    #
    # @return [Client] `wallet.client`
    def client = wallet.client

    # @return [String] the checksummed sender address (`params[:from]`)
    def from = params[:from]

    # @return [String, nil] the checksummed recipient address, or nil for a contract creation
    def to = params[:to]

    # @return [Integer] the amount of wei transferred
    def value = params[:value]

    # @return [String] the calldata as `0x` hex, or `""` when there is none
    def data = params[:data]

    # @return [Integer] the nonce the bytes were signed with; a {#replacement} reuses it
    def nonce = params[:nonce]

    # @return [Integer] the gas limit
    def gas = params[:gas]

    # @return [Integer] the chain id the transaction is valid on (EIP-155)
    def chain_id = params[:chain_id]

    # @return [Integer, nil] the EIP-1559 max fee per gas in wei, or nil for a legacy transaction
    def max_fee_per_gas = params[:max_fee_per_gas]

    # @return [Integer, nil] the EIP-1559 max priority fee per gas in wei, or nil for a legacy transaction
    def max_priority_fee_per_gas = params[:max_priority_fee_per_gas]

    # @return [Integer, nil] the gas price in wei for a legacy (type 0) transaction, or nil for EIP-1559
    def gas_price = params[:gas_price]

    # @return [Boolean] true when this is a legacy (type 0) transaction, i.e. {#gas_price} is set
    def legacy? = !gas_price.nil?

    # Broadcasts the signed bytes with `eth_sendRawTransaction`.
    #
    # The returned {Transaction} carries the locally computed {#hash}, not the value answered by the node; if
    # the node reports a different hash a warning is logged through `client.logger`, but the local hash is
    # still the one to track. Revert errors raised by the node are enriched with {#interface} when present.
    #
    # @return [Transaction] a handle on the broadcast transaction, identified by {#hash}
    # @raise [BlockGiven::ContractRevertError] when the node rejects the transaction with revert data (decoded
    #   to a named custom error when {#interface} knows its selector)
    # @raise [BlockGiven::RpcError] for any other node-side rejection (nonce too low, underpriced, ...)
    # @example
    #   tx = signed.broadcast
    #   tx.hash == signed.hash # => true
    #   tx.wait!
    def broadcast
      sent = with_decoded_errors { client.send_raw_transaction(raw) }
      unless sent.hash.to_s.casecmp?(hash)
        client.logger.warn do
          "[block_given] node returned #{sent.hash} for signed transaction #{hash}"
        end
      end
      transaction
    end
    alias submit broadcast

    # The {Transaction} handle for {#hash}, without broadcasting anything (status, receipt, confirmations...).
    #
    # @return [Transaction] the same handle `client.transaction(hash)` returns
    def transaction = client.transaction(hash)

    # Re-signs the same payload with the same nonce and higher fees, to replace a transaction stuck in the
    # mempool.
    #
    # Each fee becomes the maximum of the current fee multiplied by `fee_multiplier` (rounded up) and a fresh
    # estimate from the node ({Client#estimate_fees_per_gas} for EIP-1559, {Client#gas_price} for legacy), so
    # the replacement both satisfies the node's bump rule and catches up with the market. For EIP-1559 the
    # max fee is also kept at or above the priority fee. Everything else (`to`, `value`, `data`, `gas`,
    # `nonce`, `chain_id`, `access_list`, {#interface}) is reused. Both transactions share a nonce: only one
    # can be mined, the other is rejected by the node.
    #
    # @param fee_multiplier [Numeric] multiplier applied to the current fees; must be at least
    #   {MIN_REPLACEMENT_MULTIPLIER} (1.1), defaults to {DEFAULT_REPLACEMENT_MULTIPLIER} (1.125)
    # @return [SignedTransaction] a new signed transaction with the same nonce and higher fees, not broadcast
    # @raise [BlockGiven::InvalidArgumentError] when `fee_multiplier` is below 1.1, or when the instance has no
    #   fee parameters (neither `gas_price` nor both EIP-1559 fields; rebuild it with {.from_raw})
    # @raise [BlockGiven::ContractRevertError] when the fee estimation itself is rejected by the node with
    #   revert data
    # @example
    #   faster = signed.replacement(fee_multiplier: 1.5)
    #   faster.nonce == signed.nonce # => true
    #   faster.broadcast
    def replacement(fee_multiplier: DEFAULT_REPLACEMENT_MULTIPLIER)
      if fee_multiplier < MIN_REPLACEMENT_MULTIPLIER
        raise InvalidArgumentError, "fee_multiplier must be >= #{MIN_REPLACEMENT_MULTIPLIER} (got #{fee_multiplier})"
      end
      raise InvalidArgumentError, "cannot replace a transaction without fee params (use .from_raw)" unless fees?

      wallet.signed_transaction(
        to: to, value: value, data: data, gas: gas, nonce: nonce, chain_id: chain_id,
        access_list: params[:access_list], **with_decoded_errors { bumped_fees(fee_multiplier) }
      ).with_interface(interface)
    end

    # Everything needed to persist and later rebuild the transaction.
    #
    # @return [Hash{Symbol => Object}] {#params} merged with `:hash` and `:raw`
    def to_h = params.merge(hash: hash, raw: raw)

    # @return [String] the transaction {#hash}
    def to_s = hash

    # Two signed transactions are equal when their signed bytes are identical.
    #
    # @param other [Object] the object to compare with
    # @return [Boolean] true when `other` is a {SignedTransaction} with the same {#raw} bytes
    def ==(other) = other.is_a?(SignedTransaction) && other.raw == raw

    # Debug representation with the hash, nonce and recipient; never includes the raw bytes.
    #
    # @return [String] e.g. `#<BlockGiven::SignedTransaction 0x... nonce=12 to=0x...>`
    def inspect = "#<BlockGiven::SignedTransaction #{hash} nonce=#{nonce} to=#{to}>"

    private

    def fees? = legacy? || (max_fee_per_gas && max_priority_fee_per_gas)

    def bumped_fees(multiplier)
      if legacy?
        { gas_price: [bump(gas_price, multiplier), client.gas_price].max }
      else
        estimated = client.estimate_fees_per_gas
        priority = [bump(max_priority_fee_per_gas, multiplier), estimated[:max_priority_fee_per_gas]].max
        max_fee = [bump(max_fee_per_gas, multiplier), estimated[:max_fee_per_gas], priority].max
        { max_fee_per_gas: max_fee, max_priority_fee_per_gas: priority }
      end
    end

    def bump(fee, multiplier) = (fee * multiplier).ceil

    def with_decoded_errors
      yield
    rescue ContractRevertError => e
      raise interface ? e.decode_with(interface) : e
    end
  end
end
