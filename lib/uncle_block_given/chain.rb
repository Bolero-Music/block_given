# frozen_string_literal: true

module UncleBlockGiven
  # Static description of an EVM network, similar to viem/chains.
  Chain = Struct.new(
    :id, :name, :network, :native_currency, :rpc_urls, :block_explorer_url, :alchemy_network, :testnet,
    keyword_init: true
  ) do
    def initialize(id:, name:, network: nil, native_currency: nil, rpc_urls: [], block_explorer_url: nil,
                   alchemy_network: nil, testnet: false)
      super(
        id: id, name: name, network: network || name.to_s.downcase.gsub(/[^a-z0-9]+/, "-"),
        native_currency: native_currency || { name: "Ether", symbol: "ETH", decimals: 18 },
        rpc_urls: Array(rpc_urls), block_explorer_url: block_explorer_url,
        alchemy_network: alchemy_network, testnet: testnet
      )
    end

    def testnet? = !!testnet

    def explorer_tx_url(hash)
      block_explorer_url && "#{block_explorer_url}/tx/#{hash}"
    end

    def explorer_address_url(address)
      block_explorer_url && "#{block_explorer_url}/address/#{address}"
    end

    def to_s = "#{name} (#{id})"
    def inspect = "#<UncleBlockGiven::Chain #{self}>"
  end

  module Chains
    MAINNET = Chain.new(
      id: 1, name: "Ethereum", network: "mainnet",
      rpc_urls: ["https://eth.merkle.io"], block_explorer_url: "https://etherscan.io",
      alchemy_network: "eth-mainnet"
    )
    SEPOLIA = Chain.new(
      id: 11_155_111, name: "Sepolia", network: "sepolia",
      rpc_urls: ["https://sepolia.drpc.org"], block_explorer_url: "https://sepolia.etherscan.io",
      alchemy_network: "eth-sepolia", testnet: true
    )
    BASE = Chain.new(
      id: 8453, name: "Base", network: "base",
      rpc_urls: ["https://mainnet.base.org"], block_explorer_url: "https://basescan.org",
      alchemy_network: "base-mainnet"
    )
    BASE_SEPOLIA = Chain.new(
      id: 84_532, name: "Base Sepolia", network: "base-sepolia",
      rpc_urls: ["https://sepolia.base.org"], block_explorer_url: "https://sepolia.basescan.org",
      alchemy_network: "base-sepolia", testnet: true
    )
    POLYGON = Chain.new(
      id: 137, name: "Polygon", network: "polygon",
      native_currency: { name: "POL", symbol: "POL", decimals: 18 },
      rpc_urls: ["https://polygon-rpc.com"], block_explorer_url: "https://polygonscan.com",
      alchemy_network: "polygon-mainnet"
    )
    POLYGON_AMOY = Chain.new(
      id: 80_002, name: "Polygon Amoy", network: "polygon-amoy",
      native_currency: { name: "POL", symbol: "POL", decimals: 18 },
      rpc_urls: ["https://rpc-amoy.polygon.technology"], block_explorer_url: "https://amoy.polygonscan.com",
      alchemy_network: "polygon-amoy", testnet: true
    )
    ARBITRUM = Chain.new(
      id: 42_161, name: "Arbitrum One", network: "arbitrum",
      rpc_urls: ["https://arb1.arbitrum.io/rpc"], block_explorer_url: "https://arbiscan.io",
      alchemy_network: "arb-mainnet"
    )
    ARBITRUM_SEPOLIA = Chain.new(
      id: 421_614, name: "Arbitrum Sepolia", network: "arbitrum-sepolia",
      rpc_urls: ["https://sepolia-rollup.arbitrum.io/rpc"], block_explorer_url: "https://sepolia.arbiscan.io",
      alchemy_network: "arb-sepolia", testnet: true
    )
    OPTIMISM = Chain.new(
      id: 10, name: "OP Mainnet", network: "optimism",
      rpc_urls: ["https://mainnet.optimism.io"], block_explorer_url: "https://optimistic.etherscan.io",
      alchemy_network: "opt-mainnet"
    )
    OPTIMISM_SEPOLIA = Chain.new(
      id: 11_155_420, name: "OP Sepolia", network: "optimism-sepolia",
      rpc_urls: ["https://sepolia.optimism.io"], block_explorer_url: "https://sepolia-optimism.etherscan.io",
      alchemy_network: "opt-sepolia", testnet: true
    )
    # Hardhat / Anvil / Ganache default chain, handy with a local fork.
    LOCALHOST = Chain.new(
      id: 31_337, name: "Localhost", network: "localhost",
      rpc_urls: ["http://127.0.0.1:8545"], testnet: true
    )

    ALL = [MAINNET, SEPOLIA, BASE, BASE_SEPOLIA, POLYGON, POLYGON_AMOY, ARBITRUM, ARBITRUM_SEPOLIA,
           OPTIMISM, OPTIMISM_SEPOLIA, LOCALHOST].freeze

    module_function

    # Chains.resolve(:base) / Chains.resolve("base-sepolia") / Chains.resolve(8453) / Chains.resolve(chain)
    def resolve(value)
      case value
      when Chain then value
      when Integer then find_by_id(value) || raise(ConfigurationError, "unknown chain id #{value}")
      when Symbol, String
        key = value.to_s.downcase.tr("_", "-")
        ALL.find { |c| c.network == key } || raise(ConfigurationError, "unknown chain #{value.inspect}")
      else raise ConfigurationError, "cannot resolve chain from #{value.inspect}"
      end
    end

    def find_by_id(id) = ALL.find { |c| c.id == id }
    def [](value) = resolve(value)
  end
end
