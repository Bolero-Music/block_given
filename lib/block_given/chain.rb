# frozen_string_literal: true

module BlockGiven
  # Static description of an EVM network, similar to viem/chains.
  #
  # A `Struct` with keyword initialisation; the constants in {Chains} are the instances applications use, but
  # any network can be described by building one directly (e.g. a private fork with its own id).
  #
  # @example
  #   chain = BlockGiven::Chains::BASE
  #   chain.id                          # => 8453
  #   chain.testnet?                    # => false
  #   chain.explorer_tx_url("0xabc...") # => "https://basescan.org/tx/0xabc..."
  #
  #   BlockGiven::Chain.new(id: 1337, name: "Fork", rpc_urls: "http://localhost:8545", testnet: true)
  #
  # @!attribute [rw] id
  #   EIP-155 chain id (`8453` for Base), also used in transaction signatures.
  #   @return [Integer]
  # @!attribute [rw] name
  #   Human readable name (`"Base Sepolia"`).
  #   @return [String]
  # @!attribute [rw] network
  #   URL-safe slug matched by {Chains.resolve} (`"base-sepolia"`); derived from `name` when not given.
  #   @return [String]
  # @!attribute [rw] native_currency
  #   Native coin as `{ name:, symbol:, decimals: }` (defaults to `{ name: "Ether", symbol: "ETH", decimals: 18 }`).
  #   @return [Hash{Symbol => String, Integer}]
  # @!attribute [rw] rpc_urls
  #   Public JSON-RPC endpoints; {Connectors::Http} falls back to the first one when built without a URL.
  #   @return [Array<String>]
  # @!attribute [rw] block_explorer_url
  #   Base URL of the block explorer without trailing slash (`"https://basescan.org"`), or nil when there is none.
  #   @return [String, nil]
  # @!attribute [rw] alchemy_network
  #   Alchemy subdomain for this network (`"base-mainnet"`), used by {Connectors::Alchemy} to build its
  #   endpoint; nil when Alchemy does not serve the network.
  #   @return [String, nil]
  # @!attribute [rw] testnet
  #   Whether the network is a test network (default `false`); see {#testnet?}.
  #   @return [Boolean]
  Chain = Struct.new(
    :id, :name, :network, :native_currency, :rpc_urls, :block_explorer_url, :alchemy_network, :testnet,
    keyword_init: true
  ) do
    # Build a chain description; only `id` and `name` are required.
    #
    # @param id [Integer] EIP-155 chain id
    # @param name [String] human readable name
    # @param network [String, nil] slug used for lookups; defaults to `name` downcased with runs of
    #   non-alphanumeric characters replaced by `-`
    # @param native_currency [Hash{Symbol => String, Integer}, nil] `{ name:, symbol:, decimals: }`, defaults to
    #   Ether with 18 decimals
    # @param rpc_urls [Array<String>, String] one or more public JSON-RPC endpoints (a single String is wrapped)
    # @param block_explorer_url [String, nil] explorer base URL without trailing slash
    # @param alchemy_network [String, nil] Alchemy subdomain (`"base-mainnet"`)
    # @param testnet [Boolean] whether this is a test network
    # @return [Chain]
    def initialize(id:, name:, network: nil, native_currency: nil, rpc_urls: [], block_explorer_url: nil,
                   alchemy_network: nil, testnet: false)
      super(
        id: id, name: name, network: network || name.to_s.downcase.gsub(/[^a-z0-9]+/, "-"),
        native_currency: native_currency || { name: "Ether", symbol: "ETH", decimals: 18 },
        rpc_urls: Array(rpc_urls), block_explorer_url: block_explorer_url,
        alchemy_network: alchemy_network, testnet: testnet
      )
    end

    # Whether this is a test network.
    #
    # @return [Boolean] `testnet` coerced to a strict boolean
    def testnet? = !!testnet

    # Block explorer page of a transaction.
    #
    # @param hash [String] transaction hash as a `0x` hex string
    # @return [String, nil] `"#{block_explorer_url}/tx/#{hash}"`, or nil when the chain has no explorer
    def explorer_tx_url(hash)
      block_explorer_url && "#{block_explorer_url}/tx/#{hash}"
    end

    # Block explorer page of an address (account or contract).
    #
    # @param address [String] `0x` hex address
    # @return [String, nil] `"#{block_explorer_url}/address/#{address}"`, or nil when the chain has no explorer
    def explorer_address_url(address)
      block_explorer_url && "#{block_explorer_url}/address/#{address}"
    end

    # Short human readable form.
    #
    # @return [String] `"Base (8453)"`
    def to_s = "#{name} (#{id})"

    # Compact inspection string, keeping RPC URLs and currency details out of logs.
    #
    # @return [String] `"#<BlockGiven::Chain Base (8453)>"`
    def inspect = "#<BlockGiven::Chain #{self}>"
  end

  # Catalogue of known networks and the lookup used by {Configuration#chain=} and {Client#initialize}.
  #
  # Each constant is a {Chain}. {Chains.resolve} accepts a chain, a chain id, or a network slug as a Symbol or
  # String (`:base_sepolia`, `"base-sepolia"`), so applications can keep the chain in an environment variable.
  #
  # @example
  #   BlockGiven::Chains.resolve(:base_sepolia) # => #<BlockGiven::Chain Base Sepolia (84532)>
  #   BlockGiven::Chains.resolve(8453)          # => #<BlockGiven::Chain Base (8453)>
  #   BlockGiven::Chains[ENV.fetch("CHAIN")]    # same as resolve
  module Chains
    # Ethereum mainnet: id 1, explorer https://etherscan.io.
    MAINNET = Chain.new(
      id: 1, name: "Ethereum", network: "mainnet",
      rpc_urls: ["https://eth.merkle.io"], block_explorer_url: "https://etherscan.io",
      alchemy_network: "eth-mainnet"
    )
    # Sepolia, the Ethereum testnet: id 11155111, explorer https://sepolia.etherscan.io.
    SEPOLIA = Chain.new(
      id: 11_155_111, name: "Sepolia", network: "sepolia",
      rpc_urls: ["https://sepolia.drpc.org"], block_explorer_url: "https://sepolia.etherscan.io",
      alchemy_network: "eth-sepolia", testnet: true
    )
    # Base mainnet (Coinbase L2, where Bolero contracts are deployed): id 8453, explorer https://basescan.org.
    BASE = Chain.new(
      id: 8453, name: "Base", network: "base",
      rpc_urls: ["https://mainnet.base.org"], block_explorer_url: "https://basescan.org",
      alchemy_network: "base-mainnet"
    )
    # Base Sepolia testnet: id 84532, explorer https://sepolia.basescan.org.
    BASE_SEPOLIA = Chain.new(
      id: 84_532, name: "Base Sepolia", network: "base-sepolia",
      rpc_urls: ["https://sepolia.base.org"], block_explorer_url: "https://sepolia.basescan.org",
      alchemy_network: "base-sepolia", testnet: true
    )
    # Polygon PoS mainnet (native currency POL): id 137, explorer https://polygonscan.com.
    POLYGON = Chain.new(
      id: 137, name: "Polygon", network: "polygon",
      native_currency: { name: "POL", symbol: "POL", decimals: 18 },
      rpc_urls: ["https://polygon-rpc.com"], block_explorer_url: "https://polygonscan.com",
      alchemy_network: "polygon-mainnet"
    )
    # Polygon Amoy testnet (native currency POL): id 80002, explorer https://amoy.polygonscan.com.
    POLYGON_AMOY = Chain.new(
      id: 80_002, name: "Polygon Amoy", network: "polygon-amoy",
      native_currency: { name: "POL", symbol: "POL", decimals: 18 },
      rpc_urls: ["https://rpc-amoy.polygon.technology"], block_explorer_url: "https://amoy.polygonscan.com",
      alchemy_network: "polygon-amoy", testnet: true
    )
    # Arbitrum One mainnet: id 42161, explorer https://arbiscan.io.
    ARBITRUM = Chain.new(
      id: 42_161, name: "Arbitrum One", network: "arbitrum",
      rpc_urls: ["https://arb1.arbitrum.io/rpc"], block_explorer_url: "https://arbiscan.io",
      alchemy_network: "arb-mainnet"
    )
    # Arbitrum Sepolia testnet: id 421614, explorer https://sepolia.arbiscan.io.
    ARBITRUM_SEPOLIA = Chain.new(
      id: 421_614, name: "Arbitrum Sepolia", network: "arbitrum-sepolia",
      rpc_urls: ["https://sepolia-rollup.arbitrum.io/rpc"], block_explorer_url: "https://sepolia.arbiscan.io",
      alchemy_network: "arb-sepolia", testnet: true
    )
    # OP Mainnet (Optimism): id 10, explorer https://optimistic.etherscan.io.
    OPTIMISM = Chain.new(
      id: 10, name: "OP Mainnet", network: "optimism",
      rpc_urls: ["https://mainnet.optimism.io"], block_explorer_url: "https://optimistic.etherscan.io",
      alchemy_network: "opt-mainnet"
    )
    # OP Sepolia testnet: id 11155420, explorer https://sepolia-optimism.etherscan.io.
    OPTIMISM_SEPOLIA = Chain.new(
      id: 11_155_420, name: "OP Sepolia", network: "optimism-sepolia",
      rpc_urls: ["https://sepolia.optimism.io"], block_explorer_url: "https://sepolia-optimism.etherscan.io",
      alchemy_network: "opt-sepolia", testnet: true
    )
    # Hardhat / Anvil / Ganache default chain (id 31337, RPC at http://127.0.0.1:8545, no explorer), handy with
    # a local fork.
    LOCALHOST = Chain.new(
      id: 31_337, name: "Localhost", network: "localhost",
      rpc_urls: ["http://127.0.0.1:8545"], testnet: true
    )

    # Every chain known to the gem, in declaration order; {.resolve} and {.find_by_id} search this list.
    ALL = [MAINNET, SEPOLIA, BASE, BASE_SEPOLIA, POLYGON, POLYGON_AMOY, ARBITRUM, ARBITRUM_SEPOLIA,
           OPTIMISM, OPTIMISM_SEPOLIA, LOCALHOST].freeze

    module_function

    # Resolve a chain from a {Chain}, a chain id, or a network slug given as Symbol or String.
    #
    # Slugs are compared case-insensitively against {Chain#network} after mapping underscores to dashes, so
    # `:base_sepolia`, `"BASE_SEPOLIA"` and `"base-sepolia"` all resolve to {BASE_SEPOLIA}. A {Chain} is
    # returned as-is, which lets custom chains flow through the same code path.
    #
    # @param value [BlockGiven::Chain, Integer, Symbol, String]
    # @return [BlockGiven::Chain]
    # @raise [BlockGiven::ConfigurationError] when the id or slug is unknown, or the value has another type
    # @example
    #   BlockGiven::Chains.resolve(:base)          # => #<BlockGiven::Chain Base (8453)>
    #   BlockGiven::Chains.resolve("base-sepolia") # => #<BlockGiven::Chain Base Sepolia (84532)>
    #   BlockGiven::Chains.resolve(8453)           # => #<BlockGiven::Chain Base (8453)>
    #   BlockGiven::Chains.resolve(:mumbai)        # raises BlockGiven::ConfigurationError
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

    # Look a known chain up by its chain id.
    #
    # @param id [Integer] EIP-155 chain id
    # @return [BlockGiven::Chain, nil] nil when no chain in {ALL} has this id
    def find_by_id(id) = ALL.find { |c| c.id == id }

    # Shorthand for {.resolve}, so `Chains[:base]` reads like a lookup table.
    #
    # @param value [BlockGiven::Chain, Integer, Symbol, String]
    # @return [BlockGiven::Chain]
    # @raise [BlockGiven::ConfigurationError] when the value cannot be resolved
    def [](value) = resolve(value)
  end
end
