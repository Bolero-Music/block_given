# frozen_string_literal: true

module Vium
  # A broadcast transaction identified by its hash. Wraps receipt polling.
  #
  #   tx = usdc.transfer(to: "0x...", amount: 1e6)
  #   tx.hash            # => "0x..."
  #   receipt = tx.wait  # polls until mined (see Vium.config.timeout / polling_interval)
  #   tx.wait!           # same, but raises Vium::TransactionRevertedError on failure
  class Transaction
    attr_reader :hash, :client

    def initialize(hash, client:)
      @hash = hash
      @client = client
      @receipt = nil
    end

    # Non-blocking: the receipt if the transaction is mined, nil otherwise.
    def receipt
      @receipt ||= client.get_transaction_receipt(hash)
    end

    def mined? = !receipt.nil?

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
    def inspect = "#<Vium::Transaction #{hash}#{mined_flag}>"

    private

    def mined_flag = @receipt ? " mined block=#{@receipt.block_number} status=#{@receipt.status}" : ""
  end
end
