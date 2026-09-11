# frozen_string_literal: true

module BlockGiven
  # A signed transaction that has not been broadcast yet. Its hash is derived
  # from the signed bytes, so it is known before any network call: persist
  # `hash` and `nonce`, then `broadcast`. Whatever happens to the RPC call, the
  # transaction can be found again with `client.transaction(hash)`.
  #
  #   signed = registry.prepare_write(:record, movement_id, tx: { nonce: call.nonce })
  #   call.update!(tx_hash: signed.hash, nonce: signed.nonce, status: :submitted)
  #   signed.broadcast                                  # => BlockGiven::Transaction
  #
  #   signed.replacement.broadcast                      # same nonce, fees bumped by 12.5%
  #
  # `hash` is the transaction hash (a String, like Transaction#hash), so instances
  # are not usable as Hash keys; compare them with ==.
  class SignedTransaction
    # Nodes reject a same-nonce replacement whose fees are not at least 10% higher.
    MIN_REPLACEMENT_MULTIPLIER = 1.1
    DEFAULT_REPLACEMENT_MULTIPLIER = 1.125

    # Rebuilds a SignedTransaction from persisted raw bytes (after a restart, typically), so it
    # can be broadcast again or replaced. The bytes must have been signed by `wallet`.
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

    attr_reader :raw, :hash, :params, :wallet, :interface

    # interface: an Abi::Interface used to name custom errors when the node rejects the
    # broadcast with revert data (set by Contract#prepare_write).
    def initialize(raw:, params:, wallet:, interface: nil)
      @raw = Utils.prefix_hex(raw)
      @params = params.freeze
      @wallet = wallet
      @interface = interface
      @hash = Utils.keccak256(@raw)
    end

    def with_interface(interface) = self.class.new(raw: raw, params: params, wallet: wallet, interface: interface)

    def client = wallet.client

    def from = params[:from]
    def to = params[:to]
    def value = params[:value]
    def data = params[:data]
    def nonce = params[:nonce]
    def gas = params[:gas]
    def chain_id = params[:chain_id]
    def max_fee_per_gas = params[:max_fee_per_gas]
    def max_priority_fee_per_gas = params[:max_priority_fee_per_gas]
    def gas_price = params[:gas_price]
    def legacy? = !gas_price.nil?

    # eth_sendRawTransaction. Returns a Transaction carrying the locally computed hash.
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

    # The Transaction handle for this hash, without broadcasting (status, receipt...).
    def transaction = client.transaction(hash)

    # Re-signs the same payload with the same nonce and higher fees, to replace a
    # transaction stuck in the mempool. Fees are the max of (current fees x
    # fee_multiplier) and a fresh estimate from the node, so the replacement also
    # catches up with the market. Both transactions share a nonce: only one can be mined.
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

    def to_h = params.merge(hash: hash, raw: raw)

    def to_s = hash
    def ==(other) = other.is_a?(SignedTransaction) && other.raw == raw
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
