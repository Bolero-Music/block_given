# frozen_string_literal: true

module Vium
  # A private key + (optional) client, able to sign and send transactions
  # (viem's WalletClient + Account).
  #
  #   wallet = Vium::Wallet.new(private_key: ENV["PRIVATE_KEY"])
  #   wallet.address
  #   wallet.send_transaction(to: "0x...", value: Vium::Utils.parse_ether("0.01")).wait
  class Wallet
    attr_reader :address

    def self.generate(client: nil)
      new(private_key: Eth::Key.new.private_hex, client: client)
    end

    def initialize(private_key:, client: nil)
      hex = Utils.strip_hex(private_key.to_s.strip)
      raise InvalidArgumentError, "private key must be 32 bytes hex" unless hex.match?(/\A[0-9a-fA-F]{64}\z/)

      @key = Eth::Key.new(priv: hex)
      @address = @key.address.checksummed
      @client = client
    end

    def private_key = Utils.prefix_hex(@key.private_hex)
    def public_key = Utils.prefix_hex(@key.public_hex)

    def client = @client || Vium.client
    def with_client(client) = self.class.new(private_key: private_key, client: client)
    def chain = client.chain

    def balance(block: :latest) = client.get_balance(address, block: block)
    def nonce(block: :pending) = client.get_transaction_count(address, block: block)

    # EIP-191 personal_sign. Returns the 65-byte signature as hex.
    def sign_message(message)
      Utils.prefix_hex(@key.personal_sign(message))
    end

    # EIP-712 typed data (Hash with :types, :primaryType, :domain, :message).
    def sign_typed_data(typed_data)
      Utils.prefix_hex(@key.sign_typed_data(typed_data))
    end

    # Fills in nonce / gas / fees from the client, signs and returns the raw tx hex.
    # Pass gas_price: to build a legacy (type 0) transaction instead of EIP-1559.
    def sign_transaction(to: nil, value: 0, data: nil, gas: nil, nonce: nil, max_fee_per_gas: nil,
                         max_priority_fee_per_gas: nil, gas_price: nil, chain_id: nil, access_list: nil)
      params = prepare_transaction(
        to: to, value: value, data: data, gas: gas, nonce: nonce, max_fee_per_gas: max_fee_per_gas,
        max_priority_fee_per_gas: max_priority_fee_per_gas, gas_price: gas_price, chain_id: chain_id,
        access_list: access_list
      )
      tx = Eth::Tx.new(to_eth_tx_params(params))
      tx.sign(@key)
      Utils.prefix_hex(tx.hex)
    end

    def send_transaction(**params)
      client.send_raw_transaction(sign_transaction(**params))
    end

    # Resolves every missing field (nonce, gas, fees, chain id) without signing.
    def prepare_transaction(to: nil, value: 0, data: nil, gas: nil, nonce: nil, max_fee_per_gas: nil,
                            max_priority_fee_per_gas: nil, gas_price: nil, chain_id: nil, access_list: nil)
      to = Utils.checksum_address(to) if to
      value = coerce_wei(value)
      data = data.nil? || data.empty? ? "" : Utils.prefix_hex(data)

      params = {
        from: address, to: to, value: value, data: data,
        chain_id: chain_id || client.chain.id,
        nonce: nonce || self.nonce,
        gas: gas || estimate_gas(to: to, data: data, value: value),
        access_list: access_list
      }

      if gas_price
        params[:gas_price] = gas_price
      else
        fees = if max_fee_per_gas && max_priority_fee_per_gas
                 { max_fee_per_gas: max_fee_per_gas, max_priority_fee_per_gas: max_priority_fee_per_gas }
               else
                 estimated = client.estimate_fees_per_gas
                 { max_fee_per_gas: max_fee_per_gas || estimated[:max_fee_per_gas],
                   max_priority_fee_per_gas: max_priority_fee_per_gas || estimated[:max_priority_fee_per_gas] }
               end
        params.merge!(fees)
      end
      params
    end

    def ==(other) = other.is_a?(Wallet) && other.address == address
    alias eql? ==
    def hash = address.hash
    def to_s = address
    def inspect = "#<Vium::Wallet #{address}>"

    private

    def estimate_gas(to:, data:, value:)
      raise InvalidArgumentError, "contract creation requires an explicit gas: value" if to.nil?

      estimate = client.estimate_gas(to: to, data: data, from: address, value: value)
      (estimate * Vium.config.gas_multiplier).ceil
    end

    def coerce_wei(value)
      case value
      when nil then 0
      when Integer then value
      when Float, BigDecimal, Rational
        unless value == value.to_i
          raise InvalidArgumentError,
                "value must be an integer amount of wei (use Vium::Utils.parse_ether)"
        end

        value.to_i
      when String then Utils.hex?(value) ? Utils.hex_to_int(value) : Integer(value, 10)
      else raise InvalidArgumentError, "invalid value: #{value.inspect}"
      end
    end

    def to_eth_tx_params(params)
      base = {
        chain_id: params[:chain_id], nonce: params[:nonce], gas_limit: params[:gas],
        to: params[:to], value: params[:value], data: params[:data]
      }
      if params[:gas_price]
        base.merge(gas_price: params[:gas_price])
      else
        base[:access_list] = params[:access_list] || []
        base.merge(priority_fee: params[:max_priority_fee_per_gas], max_gas_fee: params[:max_fee_per_gas])
      end
    end
  end
end
