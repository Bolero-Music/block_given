# frozen_string_literal: true

module BlockGiven
  # A private key plus an optional {Client}, able to sign messages and to prepare, sign and send
  # transactions (the equivalent of viem's WalletClient + Account).
  #
  # Every value and fee is an Integer amount of wei. Transactions are EIP-1559 (type 2) by default;
  # passing `gas_price:` to any transaction method builds a legacy (type 0) transaction instead.
  # Missing fields (nonce, gas, fees, chain id) are resolved from {#client} at signing time.
  #
  # @example Create a wallet and send ether
  #   wallet = BlockGiven::Wallet.new(private_key: ENV["PRIVATE_KEY"])
  #   wallet.address # => "0xAbC..." (EIP-55 checksummed)
  #   wallet.send_transaction(to: "0x...", value: BlockGiven::Utils.parse_ether("0.01")).wait
  class Wallet
    # @return [String] the EIP-55 checksummed address derived from the private key
    attr_reader :address

    # Creates a wallet with a freshly generated random private key.
    #
    # @param client [Client, nil] client used for RPC calls; when nil, {BlockGiven.client} is used
    # @return [Wallet] a new wallet holding the generated key
    def self.generate(client: nil)
      new(private_key: Eth::Key.new.private_hex, client: client)
    end

    # Builds a wallet from an existing private key.
    #
    # @param private_key [String] 32-byte private key as 64 hex characters, with or without the `0x` prefix
    #   (surrounding whitespace is ignored)
    # @param client [Client, nil] client used for nonce, gas and fee lookups and for broadcasting; when nil,
    #   every call falls back to {BlockGiven.client}
    # @raise [BlockGiven::InvalidArgumentError] when the key is not exactly 32 bytes of hex
    # @example
    #   wallet = BlockGiven::Wallet.new(private_key: "0x4c0883a6...d1e6") # 64 hex chars
    #   wallet.address # => "0x..."
    def initialize(private_key:, client: nil)
      hex = Utils.strip_hex(private_key.to_s.strip)
      raise InvalidArgumentError, "private key must be 32 bytes hex" unless hex.match?(/\A[0-9a-fA-F]{64}\z/)

      @key = Eth::Key.new(priv: hex)
      @address = @key.address.checksummed
      @client = client
    end

    # The private key, for persistence or export. It is never included in {#inspect} or {#to_s}.
    #
    # @return [String] the 32-byte private key as `0x`-prefixed hex
    def private_key = Utils.prefix_hex(@key.private_hex)

    # The uncompressed public key matching {#private_key}.
    #
    # @return [String] the 65-byte public key as `0x`-prefixed hex
    def public_key = Utils.prefix_hex(@key.public_hex)

    # The client used for every RPC call made by this wallet.
    #
    # @return [Client] the client given to {#initialize}, or {BlockGiven.client} when none was given
    def client = @client || BlockGiven.client

    # Returns a copy of this wallet (same key) bound to another client, e.g. to sign on another chain.
    #
    # @param client [Client] the client the copy will use
    # @return [Wallet] a new wallet with the same private key and the given client
    def with_client(client) = self.class.new(private_key: private_key, client: client)

    # The chain of {#client}.
    #
    # @return [Chain] the chain the wallet's transactions are built for
    def chain = client.chain

    # Balance of {#address} in wei.
    #
    # @param block [Symbol, Integer, String] block tag (`:latest`, `:pending`, `:safe`, `:finalized`, `:earliest`)
    #   or block number
    # @return [Integer] the balance in wei at that block
    def balance(block: :latest) = client.get_balance(address, block: block)

    # Transaction count of {#address}, i.e. the nonce the next transaction should use.
    #
    # @param block [Symbol, Integer, String] block tag or number; defaults to `:pending` so that transactions
    #   still waiting in the mempool are counted
    # @return [Integer] the transaction count at that block
    def nonce(block: :pending) = client.get_transaction_count(address, block: block)

    # Signs a message with the EIP-191 `personal_sign` scheme.
    #
    # The message is prefixed with `"\x19Ethereum Signed Message:\n" + length` before hashing, so the signature
    # can be verified with `ecrecover` or viem's `verifyMessage`.
    #
    # @param message [String] the message to sign, as a plain string
    # @return [String] the 65-byte signature (r, s, v) as `0x`-prefixed hex
    # @example
    #   signature = wallet.sign_message("Login to Bolero at 2024-01-01")
    #   signature # => "0x..." (132 hex characters)
    def sign_message(message)
      Utils.prefix_hex(@key.personal_sign(message))
    end

    # Signs EIP-712 typed structured data.
    #
    # @param typed_data [Hash] the EIP-712 payload with `:types`, `:primaryType`, `:domain` and `:message` keys
    #   (String keys are accepted too)
    # @return [String] the 65-byte signature (r, s, v) as `0x`-prefixed hex
    # @example Sign an ERC-2612 permit
    #   wallet.sign_typed_data(
    #     types: { EIP712Domain: [...], Permit: [{ name: "owner", type: "address" }, ...] },
    #     primaryType: "Permit",
    #     domain: { name: "USD Coin", version: "2", chainId: 8453, verifyingContract: "0x..." },
    #     message: { owner: wallet.address, spender: "0x...", value: 1_000_000, nonce: 0, deadline: 1_700_000_000 }
    #   )
    def sign_typed_data(typed_data)
      Utils.prefix_hex(@key.sign_typed_data(typed_data))
    end

    # Resolves the missing fields, signs, and returns the transaction without broadcasting it.
    #
    # The returned {SignedTransaction} knows its {SignedTransaction#hash} (keccak of the signed bytes) and
    # {SignedTransaction#nonce} before any network call: persist them, then call {SignedTransaction#broadcast}.
    # See {#prepare_transaction} for how each missing field is resolved.
    #
    # @overload signed_transaction(to: nil, value: 0, data: nil, gas: nil, nonce: nil, max_fee_per_gas: nil,
    #                              max_priority_fee_per_gas: nil, gas_price: nil, chain_id: nil, access_list: nil)
    #   @param to [String, nil] recipient address (any case, checksummed before signing); nil for contract creation
    #   @param value [Integer, String, Float, BigDecimal, Rational] amount of wei to send; Strings may be decimal
    #     or `0x` hex, non-Integer numerics must have no fractional part. Defaults to 0
    #   @param data [String, nil] calldata as hex (with or without `0x`); nil or empty means no calldata
    #   @param gas [Integer, nil] gas limit; defaults to `eth_estimateGas` multiplied by
    #     `BlockGiven.config.gas_multiplier` (rounded up)
    #   @param nonce [Integer, nil] nonce to use; defaults to the wallet's pending transaction count ({#nonce})
    #   @param max_fee_per_gas [Integer, nil] EIP-1559 max fee per gas in wei; defaults to
    #     {Client#estimate_fees_per_gas} when omitted (ignored when `gas_price:` is given)
    #   @param max_priority_fee_per_gas [Integer, nil] EIP-1559 priority fee per gas in wei; defaults to
    #     {Client#estimate_fees_per_gas} when omitted (ignored when `gas_price:` is given)
    #   @param gas_price [Integer, nil] gas price in wei; when given, a legacy (type 0) transaction is built and
    #     the EIP-1559 fee fields are not used. Never estimated: legacy transactions need an explicit value
    #   @param chain_id [Integer, nil] chain id for EIP-155 replay protection; defaults to `client.chain.id`
    #   @param access_list [Array<Hash>, nil] EIP-2930 access list; nil means an empty list (EIP-1559 only)
    # @return [SignedTransaction] the signed transaction, ready to be broadcast or persisted
    # @raise [BlockGiven::InvalidArgumentError] when `value:` is malformed or fractional, or when `to:` is nil
    #   without an explicit `gas:` (contract creation cannot be estimated here)
    # @example Persist the hash before broadcasting, replace the transaction if it gets stuck
    #   signed = wallet.signed_transaction(to: usdc_address, data: calldata)
    #   record.update!(tx_hash: signed.hash, nonce: signed.nonce, raw_tx: signed.raw)
    #   tx = signed.broadcast                         # => BlockGiven::Transaction with the same hash
    #   signed.replacement.broadcast if tx.pending?   # same nonce, fees bumped by 12.5%
    def signed_transaction(**params)
      prepared = prepare_transaction(**params)
      tx = Eth::Tx.new(to_eth_tx_params(prepared))
      tx.sign(@key)
      SignedTransaction.new(raw: Utils.prefix_hex(tx.hex), params: prepared, wallet: self)
    end

    # Signs a transaction and returns only the raw signed bytes, without broadcasting.
    #
    # Shorthand for `signed_transaction(**params).raw`; see {#signed_transaction} for the keyword semantics.
    #
    # @overload sign_transaction(to: nil, value: 0, data: nil, gas: nil, nonce: nil, max_fee_per_gas: nil,
    #                            max_priority_fee_per_gas: nil, gas_price: nil, chain_id: nil, access_list: nil)
    #   @param to [String, nil] recipient address; nil for contract creation (then `gas:` is required)
    #   @param value [Integer, String, Float, BigDecimal, Rational] amount of wei to send (default 0)
    #   @param data [String, nil] calldata as hex
    #   @param gas [Integer, nil] gas limit; default `eth_estimateGas` times `BlockGiven.config.gas_multiplier`
    #   @param nonce [Integer, nil] nonce; default the wallet's pending transaction count
    #   @param max_fee_per_gas [Integer, nil] EIP-1559 max fee in wei; default from {Client#estimate_fees_per_gas}
    #   @param max_priority_fee_per_gas [Integer, nil] EIP-1559 priority fee in wei; default from
    #     {Client#estimate_fees_per_gas}
    #   @param gas_price [Integer, nil] gas price in wei; switches to a legacy (type 0) transaction
    #   @param chain_id [Integer, nil] chain id; default `client.chain.id`
    #   @param access_list [Array<Hash>, nil] EIP-2930 access list (EIP-1559 only)
    # @return [String] the RLP-encoded signed transaction as `0x`-prefixed hex, as accepted by
    #   `eth_sendRawTransaction`
    # @raise [BlockGiven::InvalidArgumentError] same conditions as {#signed_transaction}
    def sign_transaction(**params) = signed_transaction(**params).raw

    # Signs a transaction and broadcasts it right away.
    #
    # Shorthand for `signed_transaction(**params).broadcast`; see {#signed_transaction} for the keyword semantics.
    #
    # @overload send_transaction(to: nil, value: 0, data: nil, gas: nil, nonce: nil, max_fee_per_gas: nil,
    #                            max_priority_fee_per_gas: nil, gas_price: nil, chain_id: nil, access_list: nil)
    #   @param to [String, nil] recipient address; nil for contract creation (then `gas:` is required)
    #   @param value [Integer, String, Float, BigDecimal, Rational] amount of wei to send (default 0)
    #   @param data [String, nil] calldata as hex
    #   @param gas [Integer, nil] gas limit; default `eth_estimateGas` times `BlockGiven.config.gas_multiplier`
    #   @param nonce [Integer, nil] nonce; default the wallet's pending transaction count
    #   @param max_fee_per_gas [Integer, nil] EIP-1559 max fee in wei; default from {Client#estimate_fees_per_gas}
    #   @param max_priority_fee_per_gas [Integer, nil] EIP-1559 priority fee in wei; default from
    #     {Client#estimate_fees_per_gas}
    #   @param gas_price [Integer, nil] gas price in wei; switches to a legacy (type 0) transaction
    #   @param chain_id [Integer, nil] chain id; default `client.chain.id`
    #   @param access_list [Array<Hash>, nil] EIP-2930 access list (EIP-1559 only)
    # @return [Transaction] a handle on the broadcast transaction, carrying the locally computed hash
    # @raise [BlockGiven::InvalidArgumentError] same conditions as {#signed_transaction}
    # @raise [BlockGiven::RpcError] when the node rejects the transaction (a revert during the node's
    #   pre-check is raised as {ContractRevertError})
    # @example
    #   tx = wallet.send_transaction(to: "0x...", value: BlockGiven::Utils.parse_ether("0.5"))
    #   tx.hash          # => "0x..."
    #   receipt = tx.wait!
    def send_transaction(**params) = signed_transaction(**params).broadcast

    # Resolves every missing transaction field from the client, without signing anything.
    #
    # This is the shared first step of {#signed_transaction}, {#sign_transaction} and {#send_transaction}.
    # It normalises the inputs (checksummed `to`, Integer `value`, `0x`-prefixed `data`) and fills in the
    # chain id, nonce, gas limit and fees from the node. When `gas_price:` is given the result describes a
    # legacy (type 0) transaction and contains `:gas_price`; otherwise it contains `:max_fee_per_gas` and
    # `:max_priority_fee_per_gas`.
    #
    # @param to [String, nil] recipient address (any case, checksummed in the result); nil for contract creation
    # @param value [Integer, String, Float, BigDecimal, Rational, nil] amount of wei; Strings may be decimal or
    #   `0x` hex, non-Integer numerics must have no fractional part; nil is treated as 0
    # @param data [String, nil] calldata as hex (with or without `0x`); nil or empty becomes `""`
    # @param gas [Integer, nil] gas limit; defaults to `eth_estimateGas` (from {#address}, with `to`, `data` and
    #   `value`) multiplied by `BlockGiven.config.gas_multiplier` and rounded up
    # @param nonce [Integer, nil] nonce; defaults to the wallet's pending transaction count ({#nonce})
    # @param max_fee_per_gas [Integer, nil] EIP-1559 max fee per gas in wei; when either EIP-1559 field is
    #   omitted the missing one comes from {Client#estimate_fees_per_gas}. Ignored with `gas_price:`
    # @param max_priority_fee_per_gas [Integer, nil] EIP-1559 priority fee per gas in wei; see `max_fee_per_gas`
    # @param gas_price [Integer, nil] gas price in wei for a legacy (type 0) transaction; never estimated
    # @param chain_id [Integer, nil] chain id; defaults to `client.chain.id`
    # @param access_list [Array<Hash>, nil] EIP-2930 access list, kept as given (nil when omitted)
    # @return [Hash{Symbol => Object}] the resolved parameters: `:from`, `:to`, `:value`, `:data`, `:chain_id`,
    #   `:nonce`, `:gas`, `:access_list`, plus either `:gas_price` or `:max_fee_per_gas` and
    #   `:max_priority_fee_per_gas`
    # @raise [BlockGiven::InvalidArgumentError] when `value` cannot be coerced to an Integer amount of wei (for
    #   example a fractional Float), or when `to` is nil without an explicit `gas`
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

    # Two wallets are equal when they control the same address, whatever their client.
    #
    # @param other [Object] the object to compare with
    # @return [Boolean] true when `other` is a {Wallet} with the same {#address}
    def ==(other) = other.is_a?(Wallet) && other.address == address
    alias eql? ==

    # Hash code consistent with {#==}, so wallets can be used as Hash keys and in Sets.
    #
    # @return [Integer] the hash of {#address}
    def hash = address.hash

    # @return [String] the checksummed {#address}
    def to_s = address

    # Debug representation showing only the address. The private key is never printed.
    #
    # @return [String] e.g. `#<BlockGiven::Wallet 0xAbC...>`
    def inspect = "#<BlockGiven::Wallet #{address}>"

    private

    def estimate_gas(to:, data:, value:)
      raise InvalidArgumentError, "contract creation requires an explicit gas: value" if to.nil?

      estimate = client.estimate_gas(to: to, data: data, from: address, value: value)
      (estimate * BlockGiven.config.gas_multiplier).ceil
    end

    def coerce_wei(value)
      case value
      when nil then 0
      when Integer then value
      when Float, BigDecimal, Rational
        unless value == value.to_i
          raise InvalidArgumentError,
                "value must be an integer amount of wei (use BlockGiven::Utils.parse_ether)"
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
