# frozen_string_literal: true

RSpec.describe Vium::Client do
  let(:stub) { build_stub }
  let(:client) { described_class.new(chain: :base, connector: stub, polling_interval: 0.01, timeout: 1) }

  before { Vium.configure { |c| c.logger = Logger.new(nil) } }

  it "decodes quantities" do
    expect(client.chain_id).to eq(8453)
    expect(client.block_number).to eq(16)
    expect(client.gas_price).to eq(1_000_000_000)
  end

  it "checksums addresses and formats block tags" do
    stub.stub("eth_getBalance", "0xde0b6b3a7640000")
    expect(client.get_balance(TEST_ADDRESS.downcase, block: 12)).to eq(10**18)
    expect(stub.calls_for("eth_getBalance").last).to eq([TEST_ADDRESS, "0xc"])
  end

  it "normalizes blocks" do
    block = client.get_block(:latest)
    expect(block).to include(number: 16, base_fee_per_gas: 1_000_000_000, timestamp: 1)
    expect(stub.calls_for("eth_getBlockByNumber").last).to eq(["latest", false])
  end

  it "fetches a block by hash" do
    stub.stub("eth_getBlockByHash", { "number" => "0x2" })
    expect(client.get_block("0x#{'11' * 32}")[:number]).to eq(2)
  end

  it "estimates EIP-1559 fees like viem" do
    fees = client.estimate_fees_per_gas
    expect(fees).to eq(base_fee_per_gas: 1_000_000_000, max_priority_fee_per_gas: 1_000_000,
                       max_fee_per_gas: 1_200_000_000 + 1_000_000)
  end

  it "falls back when eth_maxPriorityFeePerGas is unsupported" do
    stub.stub("eth_maxPriorityFeePerGas", Vium::RpcError.new("unsupported", code: -32_601))
    expect(client.max_priority_fee_per_gas).to eq(1_000_000_000)
  end

  it "builds call objects without empty fields" do
    stub.stub("eth_call", "0x01")
    client.call(to: USDC_BASE, data: "a9059cbb", value: 0)
    expect(stub.calls_for("eth_call").last).to eq([{ to: USDC_BASE, data: "0xa9059cbb" }, "latest"])
  end

  describe "#get_logs" do
    it "sends a filter with checksummed address and block range" do
      stub.stub("eth_getLogs", [{ "address" => USDC_BASE.downcase, "blockNumber" => "0x10", "topics" => ["0xaa"],
                                  "data" => "0x", "logIndex" => "0x1" }])
      logs = client.get_logs(address: USDC_BASE.downcase, topics: ["0xaa"], from_block: 10, to_block: :latest)
      expect(stub.calls_for("eth_getLogs").last)
        .to eq([{ address: USDC_BASE, topics: ["0xaa"], fromBlock: "0xa", toBlock: "latest" }])
      expect(logs.first).to include(block_number: 16, log_index: 1, topics: ["0xaa"])
    end
  end

  describe "#get_logs_in_chunks" do
    it "splits the range and resolves :latest" do
      stub.stub("eth_getLogs", ->(params) { [{ "blockNumber" => params.first[:toBlock], "topics" => [], "data" => "0x" }] })
      logs = client.get_logs_in_chunks(address: USDC_BASE, from_block: 1, to_block: :latest, max_block_range: 5)
      expect(stub.calls_for("eth_getLogs").map { |p| p.first.values_at(:fromBlock, :toBlock) })
        .to eq([%w[0x1 0x5], %w[0x6 0xa], %w[0xb 0xf], %w[0x10 0x10]])
      expect(logs.map { |l| l[:block_number] }).to eq([5, 10, 15, 16])
    end
  end

  describe "#wait_for_transaction_receipt" do
    let(:hash) { "0x#{'ab' * 32}" }
    let(:receipt) { { "transactionHash" => hash, "blockNumber" => "0x10", "status" => "0x1", "logs" => [] } }

    it "polls until the receipt is available" do
      stub.stub("eth_getTransactionReceipt", Vium::Connectors::Stub.sequence(nil, nil, receipt))
      result = client.wait_for_transaction_receipt(hash)
      expect(result).to be_a(Vium::Receipt)
      expect(result.status).to eq(:success)
      expect(stub.calls_for("eth_getTransactionReceipt").size).to eq(3)
    end

    it "waits for confirmations" do
      stub.stub("eth_getTransactionReceipt", receipt)
      stub.stub("eth_blockNumber", Vium::Connectors::Stub.sequence("0x10", "0x11", "0x12"))
      client.wait_for_transaction_receipt(hash, confirmations: 3)
      expect(stub.calls_for("eth_blockNumber").size).to eq(3)
    end

    it "times out" do
      stub.stub("eth_getTransactionReceipt", nil)
      expect { client.wait_for_transaction_receipt(hash, timeout: 0.05) }.to raise_error(Vium::TimeoutError)
    end
  end

  describe "#watch_block_number" do
    it "yields new block numbers in the background and stops" do
      stub.stub("eth_blockNumber", Vium::Connectors::Stub.sequence("0x10", "0x10", "0x12", "0x12"))
      seen = []
      watcher = client.watch_block_number(emit_missed: true) { |n| seen << n }
      deadline = Time.now + 1
      sleep 0.01 until seen.size >= 3 || Time.now > deadline
      watcher.stop.join(1)
      expect(seen).to eq([16, 17, 18])
      expect(watcher.running?).to be false
    end
  end

  describe "#watch_logs" do
    it "polls new block ranges and yields log batches" do
      stub.stub("eth_blockNumber", Vium::Connectors::Stub.sequence("0x10", "0x12", "0x12", "0x13"))
      stub.stub("eth_getLogs", ->(params) { [{ "blockNumber" => params.first[:toBlock], "topics" => [], "data" => "0x" }] })
      batches = []
      watcher = client.watch_logs(address: USDC_BASE) { |logs| batches << logs }
      deadline = Time.now + 1
      sleep 0.01 until batches.size >= 2 || Time.now > deadline
      watcher.stop.join(1)
      expect(stub.calls_for("eth_getLogs").map { |p| p.first.values_at(:fromBlock, :toBlock) })
        .to eq([%w[0x11 0x12], %w[0x13 0x13]])
    end

    it "catches up from from_block in chunks, lags behind the head and reports progress" do
      stub.stub("eth_blockNumber", "0x64") # head = 100
      stub.stub("eth_getLogs", [])
      progress = []
      watcher = client.watch_logs(address: USDC_BASE, from_block: 1, max_block_range: 40, confirmations: 2,
                                  on_progress: ->(from, to) { progress << [from, to] }) { |_logs| nil }
      deadline = Time.now + 1
      sleep 0.01 until progress.size >= 3 || Time.now > deadline
      watcher.stop.join(1)
      expect(progress).to eq([[1, 40], [41, 80], [81, 98]])
      expect(watcher.cursor).to eq(98)
      expect(stub.calls_for("eth_getLogs").map { |p| p.first.values_at(:fromBlock, :toBlock) })
        .to eq([%w[0x1 0x28], %w[0x29 0x50], %w[0x51 0x62]])
    end

    it "keeps polling after an error and reports it" do
      stub.stub("eth_blockNumber", Vium::Connectors::Stub.sequence("0x10", "0x11", "0x12"))
      stub.stub("eth_getLogs", Vium::Connectors::Stub.sequence(Vium::RpcError.new("flaky"), []))
      errors = []
      watcher = client.watch_logs(address: USDC_BASE) { |_logs| nil }
      watcher.on_error { |e, _| errors << e }
      deadline = Time.now + 1
      sleep 0.01 until stub.calls_for("eth_getLogs").size >= 2 || Time.now > deadline
      watcher.stop.join(1)
      expect(errors.map(&:message)).to eq(["flaky"])
      expect(stub.calls_for("eth_getLogs").size).to be >= 2
    end
  end
end
