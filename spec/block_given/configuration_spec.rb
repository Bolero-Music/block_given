# frozen_string_literal: true

RSpec.describe BlockGiven::Configuration do
  it "has sensible defaults" do
    config = BlockGiven.config
    expect(config.polling_interval).to eq(2.0)
    expect(config.timeout).to eq(180)
    expect(config.gas_multiplier).to eq(1.2)
    expect(config.confirmations).to eq(1)
  end

  it "tracks whether the logger was configured (used by the Rails railtie)" do
    expect(BlockGiven.config.logger_configured?).to be false
    BlockGiven.configure { |c| c.logger = Logger.new(nil) }
    expect(BlockGiven.config.logger_configured?).to be true
  end

  it "resolves the chain" do
    BlockGiven.configure { |c| c.chain = :base_sepolia }
    expect(BlockGiven.config.chain).to eq(BlockGiven::Chains::BASE_SEPOLIA)
  end

  it "raises a helpful error when nothing is configured" do
    expect { BlockGiven.client }.to raise_error(BlockGiven::ConfigurationError, /chain/)
    BlockGiven.configure { |c| c.chain = :base }
    expect { BlockGiven.client }.to raise_error(BlockGiven::ConfigurationError, /connector/)
  end

  it "rebuilds the default client after configure" do
    configure_block_given(build_stub)
    first = BlockGiven.client
    configure_block_given(build_stub, chain: :sepolia)
    expect(BlockGiven.client).not_to equal(first)
    expect(BlockGiven.client.chain).to eq(BlockGiven::Chains::SEPOLIA)
  end
end
