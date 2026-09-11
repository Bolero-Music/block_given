# frozen_string_literal: true

RSpec.describe UncleBlockGiven::Configuration do
  it "has sensible defaults" do
    config = UncleBlockGiven.config
    expect(config.polling_interval).to eq(2.0)
    expect(config.timeout).to eq(180)
    expect(config.gas_multiplier).to eq(1.2)
    expect(config.confirmations).to eq(1)
  end

  it "tracks whether the logger was configured (used by the Rails railtie)" do
    expect(UncleBlockGiven.config.logger_configured?).to be false
    UncleBlockGiven.configure { |c| c.logger = Logger.new(nil) }
    expect(UncleBlockGiven.config.logger_configured?).to be true
  end

  it "resolves the chain" do
    UncleBlockGiven.configure { |c| c.chain = :base_sepolia }
    expect(UncleBlockGiven.config.chain).to eq(UncleBlockGiven::Chains::BASE_SEPOLIA)
  end

  it "raises a helpful error when nothing is configured" do
    expect { UncleBlockGiven.client }.to raise_error(UncleBlockGiven::ConfigurationError, /chain/)
    UncleBlockGiven.configure { |c| c.chain = :base }
    expect { UncleBlockGiven.client }.to raise_error(UncleBlockGiven::ConfigurationError, /connector/)
  end

  it "rebuilds the default client after configure" do
    configure_uncle_block_given(build_stub)
    first = UncleBlockGiven.client
    configure_uncle_block_given(build_stub, chain: :sepolia)
    expect(UncleBlockGiven.client).not_to equal(first)
    expect(UncleBlockGiven.client.chain).to eq(UncleBlockGiven::Chains::SEPOLIA)
  end
end
