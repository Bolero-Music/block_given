# frozen_string_literal: true

RSpec.describe Vium::Chains do
  it "resolves by symbol, string and id" do
    expect(described_class.resolve(:base)).to eq(Vium::Chains::BASE)
    expect(described_class.resolve("base-sepolia")).to eq(Vium::Chains::BASE_SEPOLIA)
    expect(described_class.resolve(:base_sepolia)).to eq(Vium::Chains::BASE_SEPOLIA)
    expect(described_class.resolve(1)).to eq(Vium::Chains::MAINNET)
    expect(described_class[8453].name).to eq("Base")
  end

  it "raises on unknown chains" do
    expect { described_class.resolve(:moon) }.to raise_error(Vium::ConfigurationError)
    expect { described_class.resolve(999_999) }.to raise_error(Vium::ConfigurationError)
  end

  it "builds explorer urls" do
    expect(Vium::Chains::BASE.explorer_tx_url("0xabc")).to eq("https://basescan.org/tx/0xabc")
    expect(Vium::Chains::LOCALHOST.explorer_tx_url("0xabc")).to be_nil
  end

  it "supports custom chains" do
    chain = Vium::Chain.new(id: 4242, name: "My Fork", rpc_urls: ["http://localhost:9999"])
    expect(chain.network).to eq("my-fork")
    expect(chain.native_currency[:symbol]).to eq("ETH")
  end
end
