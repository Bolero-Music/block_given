# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Transaction do
  let(:hash) { "0x#{'ab' * 32}" }
  let(:stub) { build_stub }
  let(:client) { UncleBlockGiven::Client.new(chain: :base, connector: stub, polling_interval: 0.01, timeout: 1) }
  let(:transaction) { described_class.new(hash, client: client) }

  before { UncleBlockGiven.configure { |c| c.logger = Logger.new(nil) } }

  it "exposes the receipt without blocking" do
    stub.stub("eth_getTransactionReceipt", nil)
    expect(transaction.mined?).to be false
  end

  it "waits and raises on reverted receipts with wait!" do
    stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0x10", "status" => "0x0" })
    expect(transaction.wait.reverted?).to be true
    expect { transaction.wait! }.to raise_error(UncleBlockGiven::TransactionRevertedError) { |e| expect(e.receipt.block_number).to eq(16) }
  end

  describe "#status" do
    it "is :unknown when the node has never seen the transaction" do
      stub.stub("eth_getTransactionReceipt", nil).stub("eth_getTransactionByHash", nil)
      expect(transaction.status).to eq(:unknown)
      expect(transaction).to be_unknown
      expect(transaction).not_to be_pending
      expect(transaction).not_to be_success
      expect(transaction).not_to be_reverted
    end

    it "is :pending while the transaction waits in the mempool" do
      stub.stub("eth_getTransactionReceipt", nil).stub("eth_getTransactionByHash", { "hash" => hash, "nonce" => "0x5", "blockNumber" => nil })
      expect(transaction.status).to eq(:pending)
      expect(transaction).to be_pending
    end

    it "follows the receipt once mined, without calling eth_getTransactionByHash" do
      stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0x10", "status" => "0x1" })
      expect(transaction.status).to eq(:success)
      expect(transaction).to be_success
      expect(stub.calls_for("eth_getTransactionByHash")).to be_empty

      stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0x10", "status" => "0x0" })
      expect(described_class.new(hash, client: client).status).to eq(:reverted)
    end
  end

  it "caches the receipt until reload" do
    stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0x10", "status" => "0x1" })
    transaction.status
    transaction.status
    expect(stub.calls_for("eth_getTransactionReceipt").size).to eq(1)
    expect(transaction.reload).to equal(transaction)
    transaction.status
    expect(stub.calls_for("eth_getTransactionReceipt").size).to eq(2)
  end

  describe "#confirmations" do
    it "is 0 while not mined" do
      stub.stub("eth_getTransactionReceipt", nil)
      expect(transaction.confirmations).to eq(0)
      expect(transaction.confirmed?(1)).to be false
    end

    it "counts blocks since inclusion, latest block included" do
      stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0xc", "status" => "0x1" })
      expect(transaction.confirmations).to eq(5) # head is 0x10 = 16, mined at 12
      expect(transaction.confirmed?(5)).to be true
      expect(transaction.confirmed?(6)).to be false
      expect(transaction.confirmed?).to be true # config default: 1
    end

    it "never goes negative after a reorg moved the head back" do
      stub.stub("eth_getTransactionReceipt", { "transactionHash" => hash, "blockNumber" => "0x20", "status" => "0x1" })
      expect(transaction.confirmations).to eq(0)
    end
  end

  it "links to the explorer" do
    expect(transaction.explorer_url).to eq("https://basescan.org/tx/#{hash}")
  end
end
