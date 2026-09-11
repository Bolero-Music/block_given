# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Connectors::Stub do
  it "returns static values, sequences and procs" do
    stub = described_class.new(
      "eth_blockNumber" => described_class.sequence("0x1", "0x2"),
      "eth_getLogs" => [{ "data" => "0x" }],
      "eth_call" => ->(params) { params.first[:to] }
    )
    expect(stub.request("eth_blockNumber")).to eq("0x1")
    expect(stub.request("eth_blockNumber")).to eq("0x2")
    expect(stub.request("eth_blockNumber")).to eq("0x2")
    expect(stub.request("eth_getLogs", [{}])).to eq([{ "data" => "0x" }])
    expect(stub.request("eth_call", [{ to: "0xabc" }])).to eq("0xabc")
    expect(stub.calls.size).to eq(5)
  end

  it "raises for unknown methods and raises stubbed exceptions" do
    stub = described_class.new("eth_call" => UncleBlockGiven::RpcError.new("boom"))
    expect { stub.request("eth_chainId") }.to raise_error(UncleBlockGiven::RpcError, /no stub/)
    expect { stub.request("eth_call") }.to raise_error(UncleBlockGiven::RpcError, "boom")
  end

  it "falls back to a handler block" do
    stub = described_class.new { |method, _params, chain| "#{method}@#{chain.id}" }
    expect(stub.request("eth_chainId", [], chain: UncleBlockGiven::Chains::BASE)).to eq("eth_chainId@8453")
  end
end
