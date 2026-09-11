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

  it "links to the explorer" do
    expect(transaction.explorer_url).to eq("https://basescan.org/tx/#{hash}")
  end
end
