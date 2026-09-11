# frozen_string_literal: true

module BlockGiven
  # A transaction receipt (`eth_getTransactionReceipt`) with snake_case symbol keys and Integer quantities.
  #
  # Hashes are `0x` hex Strings; addresses are `0x` hex Strings as returned by the node (not re-checksummed);
  # every QUANTITY field (block number, gas, status...) is decoded to an Integer by {Normalizer}.
  #
  # @example
  #   receipt = tx.wait
  #   receipt.status       # => :success
  #   receipt.block_number # => 12_345_678
  #   receipt.fee          # => 21_000 * effective_gas_price, in wei
  #   receipt[:logs_bloom] # any raw field, by snake_case key
  class Receipt
    # @return [Hash{Symbol => Object}] every receipt field, with snake_case symbol keys and Integer quantities
    attr_reader :to_h

    # Wraps a raw receipt from the node.
    #
    # @param raw [Hash, Receipt] the JSON-RPC receipt object (String or Symbol keys, hex quantities), or another
    #   {Receipt} whose fields are reused as is
    def initialize(raw)
      @to_h = raw.is_a?(Receipt) ? raw.to_h : Normalizer.normalize(raw)
    end

    # @return [String] the transaction hash as `0x` hex
    def transaction_hash = to_h[:transaction_hash]

    # @return [Integer, nil] the number of the block the transaction was included in
    def block_number = to_h[:block_number]

    # @return [String, nil] the hash of the including block as `0x` hex
    def block_hash = to_h[:block_hash]

    # @return [String] the sender address as `0x` hex, as returned by the node
    def from = to_h[:from]

    # @return [String, nil] the recipient address as `0x` hex, or nil for a contract creation
    def to = to_h[:to]

    # @return [String, nil] the address of the created contract as `0x` hex, nil unless the transaction was a
    #   contract creation
    def contract_address = to_h[:contract_address]

    # @return [Integer, nil] gas consumed by this transaction alone
    def gas_used = to_h[:gas_used]

    # @return [Integer, nil] the gas price actually paid, in wei per gas (base fee + priority fee for EIP-1559)
    def effective_gas_price = to_h[:effective_gas_price]

    # @return [Integer, nil] gas consumed by the block up to and including this transaction
    def cumulative_gas_used = to_h[:cumulative_gas_used]

    # @return [Integer, nil] the position of the transaction in its block
    def transaction_index = to_h[:transaction_index]

    # Raw logs emitted by the transaction, in emission order. Decode them with a contract's `events_from`.
    #
    # @return [Array<Hash{Symbol => Object}>] normalized log objects (`:address`, `:topics`, `:data`,
    #   `:block_number`, `:log_index`, `:removed`...); an empty Array when the receipt has none
    def logs = to_h[:logs] || []

    # Outcome of the transaction.
    #
    # `:success` when the receipt status is 1, `:reverted` otherwise. Pre-Byzantium receipts have no status
    # field: they are treated as `:success`.
    #
    # @return [Symbol] `:success` or `:reverted`
    # @example
    #   receipt.status # => :reverted
    #   receipt.reverted? # => true
    def status
      return :success if to_h[:status].nil?

      to_h[:status] == 1 ? :success : :reverted
    end

    # @return [Boolean] true when {#status} is `:success`
    def success? = status == :success

    # @return [Boolean] true when {#status} is `:reverted`
    def reverted? = status == :reverted

    # Total fee paid for the transaction: `gas_used * effective_gas_price`.
    #
    # @return [Integer, nil] the fee in wei, or nil when the node did not return both fields
    def fee = gas_used && effective_gas_price ? gas_used * effective_gas_price : nil

    # Reads any receipt field by name, including chain-specific ones (e.g. `:l1_fee` on OP-stack chains).
    #
    # @param key [Symbol, String] the snake_case field name (Strings are symbolized as is)
    # @return [Object, nil] the field value, or nil when absent
    def [](key) = to_h[key.to_sym]

    # Debug representation with the hash, status, block, gas used and log count.
    #
    # @return [String] e.g. `#<BlockGiven::Receipt 0x... status=success block=123 gas_used=21000 logs=0>`
    def inspect
      "#<BlockGiven::Receipt #{transaction_hash} status=#{status} block=#{block_number} " \
        "gas_used=#{gas_used} logs=#{logs.size}>"
    end
  end
end
