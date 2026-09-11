# frozen_string_literal: true

RSpec.describe BlockGiven::Chains do
  it "resolves by symbol, string and id" do
    expect(described_class.resolve(:base)).to eq(BlockGiven::Chains::BASE)
    expect(described_class.resolve("base-sepolia")).to eq(BlockGiven::Chains::BASE_SEPOLIA)
    expect(described_class.resolve(:base_sepolia)).to eq(BlockGiven::Chains::BASE_SEPOLIA)
    expect(described_class.resolve(1)).to eq(BlockGiven::Chains::MAINNET)
    expect(described_class[8453].name).to eq("Base")
  end

  it "raises on unknown chains" do
    expect { described_class.resolve(:moon) }.to raise_error(BlockGiven::ConfigurationError)
    expect { described_class.resolve(999_999) }.to raise_error(BlockGiven::ConfigurationError)
  end

  it "builds explorer urls" do
    expect(BlockGiven::Chains::BASE.explorer_tx_url("0xabc")).to eq("https://basescan.org/tx/0xabc")
    expect(BlockGiven::Chains::LOCALHOST.explorer_tx_url("0xabc")).to be_nil
  end

  it "supports custom chains" do
    chain = BlockGiven::Chain.new(id: 4242, name: "My Fork", rpc_urls: ["http://localhost:9999"])
    expect(chain.network).to eq("my-fork")
    expect(chain.native_currency[:symbol]).to eq("ETH")
  end
end
