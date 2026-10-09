# frozen_string_literal: true

module BlockGiven
  # A broadcast transaction identified by its hash. Wraps receipt lookup, status classification and polling.
  #
  # Instances are cheap handles: nothing is fetched until a method asks the node. The receipt is memoized
  # once found (see {#receipt} and {#reload}).
  #
  # @example Wait for a contract write
  #   tx = usdc.transfer(to: "0x...", amount: 1e6)
  #   tx.hash            # => "0x..."
  #   receipt = tx.wait  # polls until mined (see BlockGiven.config.timeout / polling_interval)
  #   tx.wait!           # same, but raises BlockGiven::TransactionRevertedError on failure
  #
  # @example Classify a persisted transaction in one round trip
  #   tx = client.transaction(payout.tx_hash)
  #   case tx.status
  #   when :success  then payout.confirmed! if tx.confirmed?(5)
  #   when :reverted then payout.failed!
  #   when :pending  then signed.replacement.broadcast if payout.submitted_at < 5.minutes.ago
  #   when :unknown  then signed.broadcast   # never seen or dropped by the node: resend the same bytes
  #   end
  class Transaction
    # @!attribute [r] hash
    #   @return [String] the transaction hash as `0x` hex. A String, so this is not Ruby's Object#hash and
    #     instances are not usable as Hash keys
    # @!attribute [r] client
    #   @return [Client] the client used to query the node
    attr_reader :hash, :client

    # Builds a handle on a transaction hash. Applications usually get instances from {Client#transaction},
    # {SignedTransaction#broadcast} or contract writes rather than calling this directly.
    #
    # @param hash [String] the transaction hash as `0x` hex
    # @param client [Client] the client used to query the node
    def initialize(hash, client:)
      @hash = hash
      @client = client
      @receipt = nil
    end

    # The receipt, without blocking: nil while the transaction is not mined.
    #
    # Cached once found: call {#reload} (or build a fresh handle with {Client#transaction}) to query the node
    # again, e.g. on every tick of a long-lived worker.
    #
    # @return [Receipt, nil] the receipt once the transaction is mined, nil otherwise
    def receipt
      @receipt ||= client.get_transaction_receipt(hash)
    end

    # Forgets the memoized receipt so the next call to {#receipt} (or any method built on it) asks the node.
    #
    # @return [self]
    def reload
      @receipt = nil
      self
    end

    # @return [Boolean] true when a receipt exists, i.e. the transaction is included in a block
    def mined? = !receipt.nil?

    # Classifies the transaction in one RPC round trip (two while it is not mined).
    #
    # - `:success` / `:reverted` when mined, from {Receipt#status}
    # - `:pending` when not mined but `eth_getTransactionByHash` knows it (waiting in the mempool)
    # - `:unknown` when the node has never seen it or dropped it; it is then safe to re-broadcast the same
    #   signed bytes or a {SignedTransaction#replacement}
    #
    # @return [Symbol] one of `:success`, `:reverted`, `:pending`, `:unknown`
    # @example
    #   case tx.status
    #   when :success  then record.confirmed!
    #   when :reverted then record.failed!
    #   when :pending  then wait_a_bit
    #   when :unknown  then signed.broadcast
    #   end
    def status
      return receipt.status if mined?

      details ? :pending : :unknown
    end

    # @return [Boolean] true when mined with a successful receipt status
    def success? = mined? && receipt.success?

    # @return [Boolean] true when mined with a failed receipt status
    def reverted? = mined? && receipt.reverted?

    # @return [Boolean] true when {#status} is `:pending` (known by the node, not mined)
    def pending? = status == :pending

    # @return [Boolean] true when {#status} is `:unknown` (never seen or dropped by the node)
    def unknown? = status == :unknown

    # Number of blocks since inclusion: `head - block_number + 1`.
    #
    # 1 when mined in the latest block, 0 while not mined. Never negative, even if the node answers with a
    # head behind the receipt's block (e.g. a lagging load-balanced provider).
    #
    # @return [Integer] the confirmation count
    def confirmations
      return 0 unless mined?

      [client.block_number - receipt.block_number + 1, 0].max
    end

    # Non-blocking counterpart of `wait(confirmations:)`.
    #
    # @param count [Integer, nil] required confirmations; defaults to `BlockGiven.config.confirmations`
    # @return [Boolean] true when {#confirmations} is at least `count`
    def confirmed?(count = nil) = confirmations >= (count || BlockGiven.config.confirmations)

    # Blocks until the transaction is mined and confirmed, then memoizes and returns the receipt.
    #
    # Polls `eth_getTransactionReceipt` through {Client#wait_for_transaction_receipt}. The receipt is returned
    # whatever its status; use {#wait!} to raise on revert.
    #
    # @param confirmations [Integer, nil] blocks to wait for after inclusion; defaults to
    #   `BlockGiven.config.confirmations`
    # @param timeout [Numeric, nil] seconds before giving up; defaults to the client's timeout
    #   (`BlockGiven.config.timeout`)
    # @param polling_interval [Numeric, nil] seconds between two polls; defaults to the client's polling interval
    #   (`BlockGiven.config.polling_interval`)
    # @return [Receipt] the mined receipt
    # @raise [BlockGiven::TimeoutError] when the receipt is not available (or not confirmed) within `timeout`
    def wait(confirmations: nil, timeout: nil, polling_interval: nil)
      @receipt = client.wait_for_transaction_receipt(
        hash, confirmations: confirmations, timeout: timeout, polling_interval: polling_interval
      )
    end

    # Same as {#wait} but raises when the mined transaction reverted.
    #
    # @param options [Hash] forwarded to {#wait} (`confirmations:`, `timeout:`, `polling_interval:`)
    # @return [Receipt] the mined receipt, guaranteed successful
    # @raise [BlockGiven::TransactionRevertedError] when the receipt status is `:reverted`; the error exposes the
    #   receipt
    # @raise [BlockGiven::TimeoutError] when the receipt is not available within the timeout
    def wait!(**options)
      receipt = wait(**options)
      raise TransactionRevertedError, receipt if receipt.reverted?

      receipt
    end

    # The transaction object as the node knows it (`eth_getTransactionByHash`), never memoized.
    #
    # @return [Hash{Symbol => Object}, nil] the normalized transaction (snake_case symbol keys, Integer
    #   quantities), or nil while the node does not know the hash
    def details = client.get_transaction(hash)

    # Link to the transaction on the chain's block explorer.
    #
    # @return [String, nil] the URL, or nil when the client's chain has no explorer configured
    def explorer_url = client.chain&.explorer_tx_url(hash)

    # @return [String] the transaction {#hash}
    def to_s = hash

    # Two handles are equal when they point at the same hash, whatever their client.
    #
    # @param other [Object] the object to compare with
    # @return [Boolean] true when `other` is a {Transaction} with the same {#hash}
    def ==(other) = other.is_a?(Transaction) && other.hash == hash

    # Debug representation; includes block and status only when a receipt is already memoized (no RPC call).
    #
    # @return [String] e.g. `#<BlockGiven::Transaction 0x... mined block=123 status=success>`
    def inspect = "#<BlockGiven::Transaction #{hash}#{mined_flag}>"

    private

    def mined_flag = @receipt ? " mined block=#{@receipt.block_number} status=#{@receipt.status}" : ""
  end
end
