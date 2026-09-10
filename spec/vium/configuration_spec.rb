# frozen_string_literal: true

RSpec.describe Vium::Configuration do
  it "has sensible defaults" do
    config = Vium.config
    expect(config.polling_interval).to eq(2.0)
    expect(config.timeout).to eq(180)
    expect(config.gas_multiplier).to eq(1.2)
    expect(config.confirmations).to eq(1)
  end

  it "resolves the chain" do
    Vium.configure { |c| c.chain = :base_sepolia }
    expect(Vium.config.chain).to eq(Vium::Chains::BASE_SEPOLIA)
  end

  it "raises a helpful error when nothing is configured" do
    expect { Vium.client }.to raise_error(Vium::ConfigurationError, /chain/)
    Vium.configure { |c| c.chain = :base }
    expect { Vium.client }.to raise_error(Vium::ConfigurationError, /connector/)
  end

  it "rebuilds the default client after configure" do
    configure_vium(build_stub)
    first = Vium.client
    configure_vium(build_stub, chain: :sepolia)
    expect(Vium.client).not_to equal(first)
    expect(Vium.client.chain).to eq(Vium::Chains::SEPOLIA)
  end
end
