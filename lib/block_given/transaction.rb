# frozen_string_literal: true

module BlockGiven
  # A broadcast transaction identified by its hash. Wraps receipt polling.
  #
  #   tx = usdc.transfer(to: "0x...", amount: 1e6)
  #   tx.hash            # => "0x..."
  #   receipt = tx.wait  # polls until mined (see BlockGiven.config.timeout / polling_interval)
  #   tx.wait!           # same, but raises BlockGiven::TransactionRevertedError on failure
  class Transaction
    attr_reader :hash, :client

    def initialize(hash, client:)
      @hash = hash
      @client = client
      @receipt = nil
    end

    # Non-blocking: the receipt if the transaction is mined, nil otherwise. Cached once
    # found: call #reload (or build a fresh handle with client.transaction) to re-query the
    # node, e.g. on every tick of a long-lived worker.
    def receipt
      @receipt ||= client.get_transaction_receipt(hash)
    end

    def reload
      @receipt = nil
      self
    end

    def mined? = !receipt.nil?

    # One RPC round trip to classify the transaction (two while it is not mined):
    #   :success / :reverted  mined, from the receipt status
    #   :pending              known by the node, waiting in the mempool
    #   :unknown              the node has never seen it, or dropped it: safe to re-broadcast
    #                         the same signed bytes (see SignedTransaction#replacement)
    def status
      return receipt.status if mined?

      details ? :pending : :unknown
    end

    def success? = mined? && receipt.success?
    def reverted? = mined? && receipt.reverted?
    def pending? = status == :pending
    def unknown? = status == :unknown

    # Blocks since inclusion, 1 when mined in the latest block, 0 while not mined.
    def confirmations
      return 0 unless mined?

      [client.block_number - receipt.block_number + 1, 0].max
    end

    # Non-blocking counterpart of wait(confirmations:). Defaults to BlockGiven.config.confirmations.
    def confirmed?(count = nil) = confirmations >= (count || BlockGiven.config.confirmations)

    def wait(confirmations: nil, timeout: nil, polling_interval: nil)
      @receipt = client.wait_for_transaction_receipt(
        hash, confirmations: confirmations, timeout: timeout, polling_interval: polling_interval
      )
    end

    def wait!(**options)
      receipt = wait(**options)
      raise TransactionRevertedError, receipt if receipt.reverted?

      receipt
    end

    # Raw transaction object from the node (nil while it is not yet known).
    def details = client.get_transaction(hash)

    def explorer_url = client.chain&.explorer_tx_url(hash)

    def to_s = hash
    def ==(other) = other.is_a?(Transaction) && other.hash == hash
    def inspect = "#<BlockGiven::Transaction #{hash}#{mined_flag}>"

    private

    def mined_flag = @receipt ? " mined block=#{@receipt.block_number} status=#{@receipt.status}" : ""
  end
end
