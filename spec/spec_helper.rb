# frozen_string_literal: true

require "bundler/setup"

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    minimum_coverage line: 90
  end
end
require "rails/all" if ENV["RAILS_COMPAT"] # Rails must be loaded before vium for the railtie
require "vium"
require "webmock/rspec"

# Hardhat / Anvil account #0 — public test key, never holds real funds.
TEST_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
TEST_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
OTHER_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

module SpecHelpers
  # 32-byte left-padded hex word
  def word(value)
    case value
    when Integer then "0x#{value.to_s(16).rjust(64, '0')}"
    when String then "0x#{Vium::Utils.strip_hex(value).rjust(64, '0')}"
    end
  end

  def abi_encode(types, values)
    Vium::Utils.bin_to_hex(Eth::Abi.encode(types, values))
  end

  def build_stub(extra = {})
    Vium::Connectors::Stub.new(
      {
        "eth_chainId" => "0x2105",
        "eth_blockNumber" => "0x10",
        "eth_getTransactionCount" => "0x5",
        "eth_estimateGas" => "0xc350",
        "eth_gasPrice" => "0x3b9aca00",
        "eth_maxPriorityFeePerGas" => "0xf4240",
        "eth_getBlockByNumber" => { "number" => "0x10", "baseFeePerGas" => "0x3b9aca00", "timestamp" => "0x1" },
        "eth_sendRawTransaction" => "0x#{'ab' * 32}"
      }.merge(extra)
    )
  end

  def configure_vium(stub, chain: :base)
    Vium.configure do |c|
      c.connector = stub
      c.chain = chain
      c.polling_interval = 0.01
      c.timeout = 2
      c.logger = Logger.new(nil)
    end
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = "tmp/rspec_status"
  config.before { Vium.reset! }
  config.after { Vium.reset! }
end
