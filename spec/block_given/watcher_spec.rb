# frozen_string_literal: true

RSpec.describe BlockGiven::Watcher do
  before { BlockGiven.configure { |c| c.logger = Logger.new(nil) } }
  after { described_class.stop_all(join: 1) }

  def wait_until(timeout: 1)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
  end

  it "registers running watchers under a unique id and unregisters them on stop" do
    a = described_class.new(interval: 0.01, name: "logs@0xabc") { nil }.start
    b = described_class.new(interval: 0.01, name: "logs@0xabc") { nil }.start

    expect(a.id).to match(/\Alogs@0xabc-[0-9a-f]{6}\z/)
    expect(a.id).not_to eq(b.id)
    expect(described_class.all).to contain_exactly(a, b)
    expect(BlockGiven.watchers.map(&:id)).to contain_exactly(a.id, b.id)
    expect(described_class.find(a.id)).to equal(a)
    expect(Thread.list.map(&:name)).to include("block_given:#{a.id}")

    described_class.stop(a.id, join: 1)
    expect(a.status).to eq(:stopped)
    expect(described_class.all).to eq([b])
    expect(described_class.find(a.id)).to be_nil
  end

  it "accepts a custom id and refuses duplicates while running" do
    watcher = described_class.new(interval: 0.01, id: "usdc-deposits") { nil }.start
    expect(described_class.find!("usdc-deposits")).to equal(watcher)
    expect { described_class.new(interval: 0.01, id: "usdc-deposits") { nil }.start }
      .to raise_error(BlockGiven::InvalidArgumentError, /already running/)
    expect { described_class.find!("nope") }.to raise_error(BlockGiven::InvalidArgumentError, /running: usdc-deposits/)

    watcher.stop.join(1)
    expect(described_class.new(interval: 0.01, id: "usdc-deposits") { nil }.start.id).to eq("usdc-deposits")
  end

  it "exposes diagnostics in to_h" do
    ticks = 0
    watcher = described_class.new(interval: 0.001, name: "diag") do |w|
      ticks += 1
      w.cursor = ticks
      raise BlockGiven::RpcError, "flaky" if ticks == 2
    end.start
    wait_until { ticks >= 3 }
    snapshot = watcher.to_h
    expect(snapshot).to include(id: watcher.id, name: "diag", status: :running, interval: 0.001, thread: "block_given:#{watcher.id}")
    expect(snapshot[:ticks]).to be >= 3
    expect(snapshot[:cursor]).to be >= 3
    expect(snapshot[:last_error]).to eq("BlockGiven::RpcError: flaky")
    expect(snapshot[:started_at]).to be_a(Time)
    expect(watcher.inspect).to include(watcher.id, "running", "last_error=BlockGiven::RpcError")
  end

  it "kills a watcher stuck in a tick" do
    entered = false
    watcher = described_class.new(interval: 0.01, id: "stuck") do
      entered = true
      sleep 60
    end.start
    wait_until { entered }
    expect(watcher.status).to eq(:running)

    described_class.kill("stuck")
    watcher.join(1)
    expect(watcher.running?).to be false
    expect(described_class.find("stuck")).to be_nil
  end

  it "stops everything with stop_all and on BlockGiven.reset!" do
    3.times { |i| described_class.new(interval: 0.01, id: "w#{i}") { nil }.start }
    expect(described_class.ids).to eq(%w[w0 w1 w2])
    described_class.stop_all(join: 1)
    expect(described_class.all).to be_empty

    described_class.new(interval: 0.01, id: "orphan") { nil }.start
    BlockGiven.reset!
    expect(described_class.all).to be_empty
  end

  it "names event watchers after the contract and event and honours id:" do
    stub = build_stub("eth_getLogs" => [])
    configure_block_given(stub)
    usdc = TestERC20.at(USDC_BASE)
    watcher = usdc.watch_event(:Transfer, id: "usdc-transfers") { |_e| nil }
    expect(watcher.id).to eq("usdc-transfers")
    expect(watcher.name).to eq("Transfer@TestERC20(0x833589fC)")
    anonymous = BlockGiven.client.watch_block_number { |_n| nil }
    expect(anonymous.id).to start_with("block_number-")
  end
end
