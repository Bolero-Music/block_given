# frozen_string_literal: true

module BlockGiven
  # Base class for typed contracts: declare an ABI and every ABI function becomes a Ruby method.
  #
  # Subclasses describe the contract with the class-level DSL ({Contract.abi} / {Contract.abi_file},
  # optionally {Contract.address} and {Contract.chain}). Instances bind that ABI to an address and,
  # optionally, to a {BlockGiven::Wallet} (needed for writes) or an explicit {BlockGiven::Client}.
  #
  # ## Dynamic methods
  #
  # {Contract.define_abi_methods!} defines one instance method per ABI function name, converted with
  # `Utils.snake_case` (`balanceOf` becomes `#balance_of`). Every generated method has the signature
  # `(*args, tx: {}, **kwargs)`:
  #
  # - ABI inputs are passed either positionally (`transfer(to, amount)`) or as keywords named after the
  #   snake_cased input names (`transfer(to: ..., value: ...)`); mixing both raises `InvalidArgumentError`.
  #   Inputs without a name in the ABI are positional only.
  # - `tx:` is the only reserved keyword. It takes a Hash whose keys must belong to {TX_OPTIONS}
  #   (`value`, `gas`, `nonce`, `max_fee_per_gas`, `max_priority_fee_per_gas`, `gas_price`, `from`,
  #   `block`); any other key raises `InvalidArgumentError`. Every other keyword maps to an ABI input, so
  #   an ERC20 `value` input never collides with the wei amount (`tx: { value: }`).
  # - `view` / `pure` functions run `eth_call` and return the decoded output (see {#read}); every other
  #   function is signed and broadcast and returns a {BlockGiven::Transaction} (see {#write}).
  # - Names clashing with an existing `Contract` method (`send`, `class`, `address`, `read`...) are not
  #   defined; call them through {#read} / {#write} with the ABI name instead.
  # - Overloaded functions are resolved by positional arity, by the set of keyword names, or by passing the
  #   full signature (`"safeMint(address,bytes)"`) to {#read} / {#write}. Ambiguity raises
  #   `AmbiguousFunctionError`. See {Abi::Interface#function}.
  #
  # @example Declaring and using a contract
  #   class Usdc < BlockGiven::Contract
  #     abi_file "abis/erc20.json"   # your app's ABI file (see BlockGiven.config.abi_path)
  #     address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  #   end
  #
  #   usdc = Usdc.new(wallet: BlockGiven::Wallet.new(private_key: "0x..."))
  #   usdc.balance_of(wallet.address)                       # eth_call, decoded
  #   tx = usdc.transfer(to: "0x...", value: 1e6)           # signed + broadcast -> BlockGiven::Transaction
  #   tx.wait!                                              # polls the receipt
  #
  # @example Transaction / call overrides in the reserved `tx:` keyword
  #   vault.deposit(amount, tx: { value: BlockGiven::Utils.parse_ether("0.1"), gas: 200_000 })
  #   token.balance_of(addr, tx: { block: 18_000_000 })
  #
  # @example Binding the same ABI to several addresses
  #   Erc20.at("0x4200000000000000000000000000000000000006", chain: :base)
  class Contract
    # Keys accepted in the `tx:` Hash of contract methods; any other key raises `InvalidArgumentError`.
    TX_OPTIONS = %i[value gas nonce max_fee_per_gas max_priority_fee_per_gas gas_price from block].freeze

    class << self
      # The parsed ABI declared with {.abi} / {.abi_file}.
      #
      # @return [Abi::Interface, nil] `nil` until an ABI is declared
      attr_reader :interface

      # Declares the ABI (and defines the dynamic methods), or returns the raw ABI definitions.
      #
      # @param source [Array<Hash>, Hash, String, Pathname, Abi::Interface, nil] an ABI Array, a
      #   Hardhat/Foundry artifact Hash with an `"abi"` key, a JSON String, a Pathname to a JSON file or an
      #   already parsed {Abi::Interface}; `nil` to read the current ABI
      # @return [Abi::Interface] the parsed interface when `source` is given
      # @return [Array<Hash>, nil] the raw ABI definitions when called without argument (`nil` if none)
      # @raise [BlockGiven::AbiError] when the source cannot be parsed as an ABI
      # @example
      #   class Erc20 < BlockGiven::Contract
      #     abi JSON.parse(File.read("abis/erc20.json"))
      #   end
      #   Erc20.abi # => [{"type"=>"function", "name"=>"balanceOf", ...}, ...]
      def abi(source = nil)
        return interface&.raw if source.nil?

        @interface = Abi::Interface.parse(source)
        define_abi_methods!
        @interface
      end

      # Declares the ABI from a JSON file (a Hardhat/Foundry artifact or a bare ABI Array).
      #
      # Relative paths are resolved against `BlockGiven.config.abi_path` when it is set: ABIs live in
      # your application, never in the gem.
      #
      # @param path [String, Pathname] absolute path, or path relative to `BlockGiven.config.abi_path`
      # @return [Abi::Interface] the parsed interface
      # @raise [BlockGiven::AbiError] when the file does not exist or is not a valid ABI
      # @example
      #   BlockGiven.configure { |c| c.abi_path = Rails.root.join("config/abis") }
      #
      #   class CatalogShares < BlockGiven::Contract
      #     abi_file "CatalogShares.json"
      #   end
      def abi_file(path)
        base = BlockGiven.config.abi_path
        path = File.join(base.to_s, path.to_s) if base && !File.absolute_path?(path.to_s)
        raise AbiError, "ABI file not found: #{path}" unless File.file?(path)

        abi(File.read(path))
      end

      # Sets or returns the default address used by {.new} when no `address:` is given.
      #
      # Instances can still target another deployment with `.new(address: ...)` or {.at}.
      #
      # @param value [String, #address, nil] the contract address (checksummed on storage); `nil` to read
      # @return [String, nil] the checksummed default address, or `nil` when none is declared
      # @raise [BlockGiven::InvalidAddressError] when `value` is not a valid address
      # @example
      #   class Usdc < BlockGiven::Contract
      #     abi_file "erc20.json"
      #     address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      #   end
      #   Usdc.address # => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      def address(value = nil)
        return @default_address if value.nil?

        @default_address = Utils.checksum_address(value)
      end
      alias default_address address

      # Sets or returns the default chain used to build a {BlockGiven::Client} for instances.
      #
      # When no chain is declared, instances use the wallet's client or the global `BlockGiven.client`
      # (see {#client}).
      #
      # @param value [Chain, Symbol, String, Integer, nil] a {Chain}, a network name (`:base`,
      #   `"base-sepolia"`) or a chain id (`8453`); `nil` to read
      # @return [Chain, nil] the resolved default chain, or `nil` when none is declared
      # @raise [BlockGiven::ConfigurationError] when the chain is unknown
      # @example
      #   class Usdc < BlockGiven::Contract
      #     abi_file "erc20.json"
      #     chain :base
      #   end
      def chain(value = nil)
        return @chain if value.nil?

        @chain = Chains.resolve(value)
      end

      # Builds an instance bound to a specific address; shorthand for `new(address: address, **options)`.
      #
      # @param address [String, #address] the contract address
      # @param options [Hash] the other {#initialize} keywords (`wallet:`, `client:`, `chain:`)
      # @return [Contract] a new instance of this contract class
      # @example
      #   weth = Erc20.at("0x4200000000000000000000000000000000000006", chain: :base)
      def at(address, **options) = new(address: address, **options)

      # ABI functions of the declared interface.
      #
      # @return [Array<Abi::Function>] empty when no ABI is declared
      def functions = interface&.functions || []

      # ABI events of the declared interface.
      #
      # @return [Array<Abi::Event>] empty when no ABI is declared
      def events = interface&.events || []

      # ABI custom errors of the declared interface.
      #
      # @return [Array<Abi::CustomError>] empty when no ABI is declared
      def errors = interface&.errors || []

      # Propagates the ABI, default address and chain to subclasses and defines their dynamic methods.
      #
      # @api private
      # @param subclass [Class] the inheriting class
      # @return [void]
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@interface, @interface)
        subclass.instance_variable_set(:@default_address, @default_address)
        subclass.instance_variable_set(:@chain, @chain)
        subclass.send(:define_abi_methods!) if @interface
      end

      private

      # Defines one instance method per ABI function name, converted to snake_case.
      #
      # Each method has the signature `(*args, tx: {}, **kwargs)` and dispatches to {#read} for
      # `view` / `pure` functions and to {#write} otherwise, resolving overloads through
      # {Abi::Interface#function}. Names already defined on `Contract` (`send`, `class`, `address`...) are
      # skipped with a debug log entry; those functions stay reachable through {#read} / {#write}.
      # Called by {.abi} and {.inherited}.
      #
      # @api private
      # @return [void]
      def define_abi_methods!
        interface.function_names.each do |ruby_name|
          if Contract.method_defined?(ruby_name) || Contract.private_method_defined?(ruby_name)
            BlockGiven.config.logger.debug do
              "[block_given] #{name}: skipping ##{ruby_name} (reserved), use read/write"
            end
            next
          end

          define_method(ruby_name) do |*args, tx: {}, **kwargs|
            function = self.class.interface.function(ruby_name, args: args, kwargs: kwargs)
            if function.read?
              read(function, *args, tx: tx, **kwargs)
            else
              write(function, *args, tx: tx, **kwargs)
            end
          end
        end
      end
    end

    # @!attribute [r] address
    #   The checksummed address this instance targets.
    #   @return [String]
    # @!attribute [r] wallet
    #   The wallet used to sign writes and as default `from` for calls.
    #   @return [BlockGiven::Wallet, nil] `nil` for read-only instances
    attr_reader :address, :wallet

    # Binds the class ABI to an address, and optionally to a wallet, client or chain.
    #
    # The client is resolved lazily by {#client}: an explicit `client:` wins, then the wallet's client
    # (when it runs on the requested chain), then a client for `chain:` / {Contract.chain}, then the
    # global `BlockGiven.client`.
    #
    # @param address [String, #address, nil] the contract address; defaults to {Contract.address}
    # @param wallet [BlockGiven::Wallet, nil] wallet used to sign writes (required by {#write} and
    #   {#prepare_write})
    # @param client [BlockGiven::Client, nil] explicit JSON-RPC client
    # @param chain [Chain, Symbol, String, Integer, nil] chain to build a client for when no `client:`
    #   is given; defaults to {Contract.chain}
    # @raise [BlockGiven::AbiError] when the class has no ABI
    # @raise [BlockGiven::InvalidArgumentError] when neither `address:` nor a default address is available
    # @raise [BlockGiven::InvalidAddressError] when the address is malformed
    def initialize(address: nil, wallet: nil, client: nil, chain: nil)
      raise AbiError, "#{self.class.name} has no ABI: declare it with `abi [...]` or `abi_file`" unless interface

      resolved = address || self.class.default_address
      raise InvalidArgumentError, "#{self.class.name}: address is required" if resolved.nil?

      @address = Utils.checksum_address(resolved)
      @wallet = wallet
      @client = client
      @chain = chain
    end

    # The parsed ABI of this contract class.
    #
    # @return [Abi::Interface]
    def interface = self.class.interface

    # The JSON-RPC client used for calls, gas estimation and logs (memoized).
    #
    # Resolution order: the `client:` given to {#initialize}; the wallet's client when no chain is
    # requested or when it already runs on that chain; a new {BlockGiven::Client} for the requested
    # chain (`chain:` or {Contract.chain}); otherwise the global `BlockGiven.client`.
    #
    # @return [BlockGiven::Client]
    # @raise [BlockGiven::ConfigurationError] when a chain name cannot be resolved, or when no chain is
    #   configured anywhere
    def client
      @client ||= begin
        chain = @chain || self.class.chain
        if wallet && (chain.nil? || wallet.client.chain == Chains.resolve(chain))
          wallet.client
        elsif chain
          Client.new(chain: chain)
        else
          BlockGiven.client
        end
      end
    end

    # The chain of the resolved {#client}.
    #
    # @return [Chain]
    def chain = client.chain

    # Returns a copy of this contract bound to another wallet, keeping the address, client and chain.
    #
    # @param wallet [BlockGiven::Wallet, nil] the wallet to sign with
    # @return [Contract] a new instance of the same class
    def with_wallet(wallet) = self.class.new(address: address, wallet: wallet, client: @client, chain: @chain)

    # --- Reads / writes -----------------------------------------------------

    # Runs `eth_call` for a function and returns its decoded output.
    #
    # Only `from:` and `block:` are meaningful here; the other {TX_OPTIONS} keys are validated but ignored.
    # A single ABI output is returned unwrapped, several outputs as an Array (see
    # {Abi::Function#decode_output}).
    #
    # @param name [String, Symbol, Abi::Function] function name (snake_case or camelCase), full signature
    #   (`"balanceOf(address)"`) or an already resolved {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param tx [Hash] call overrides; keys must belong to {TX_OPTIONS}
    # @option tx [Integer] :from address used as `msg.sender` for the call (default: the wallet address,
    #   when any)
    # @option tx [Integer, Symbol, String] :block block number or tag (`:latest`, `:safe`, `:finalized`,
    #   `:pending`, `:earliest`) the call is evaluated at (default: `:latest`)
    # @option tx [Integer] :value wei to send; accepted for uniformity, ignored by reads
    # @option tx [Integer] :gas gas limit; accepted for uniformity, ignored by reads
    # @option tx [Integer] :nonce transaction nonce; accepted for uniformity, ignored by reads
    # @option tx [Integer] :max_fee_per_gas EIP-1559 max fee; accepted for uniformity, ignored by reads
    # @option tx [Integer] :max_priority_fee_per_gas EIP-1559 priority fee; accepted for uniformity,
    #   ignored by reads
    # @option tx [Integer] :gas_price legacy gas price; accepted for uniformity, ignored by reads
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [Object, Array<Object>] the decoded output: a single value, or an Array for several outputs
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::InvalidArgumentError] on unknown `tx:` keys or malformed arguments
    # @raise [BlockGiven::ContractRevertError] when the call reverts; custom errors are decoded with the ABI
    # @example
    #   usdc.read(:balance_of, wallet.address)
    #   usdc.read("balanceOf(address)", wallet.address, tx: { block: 18_000_000 })
    #   token.read(:send, to, amount)   # ABI function whose name clashes with Object#send
    def read(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      data = function.encode(args, kwargs)
      options = tx_options(tx)
      raw = with_decoded_errors do
        client.call(to: address, data: data, from: options[:from] || wallet&.address, block: options[:block] || :latest)
      end
      function.decode_output(raw)
    end

    # Signs and broadcasts a function call; shorthand for `prepare_write(...).broadcast`.
    #
    # The sender is always the wallet: `from:` and `block:` are validated but ignored.
    #
    # @param name [String, Symbol, Abi::Function] function name (snake_case or camelCase), full signature
    #   or an already resolved {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param tx [Hash] transaction overrides; keys must belong to {TX_OPTIONS}
    # @option tx [Integer] :value wei to send along, payable functions only (default: 0)
    # @option tx [Integer] :gas gas limit (default: estimated by the wallet)
    # @option tx [Integer] :nonce nonce to use (default: the wallet's pending nonce)
    # @option tx [Integer] :max_fee_per_gas EIP-1559 max fee per gas in wei (default: estimated)
    # @option tx [Integer] :max_priority_fee_per_gas EIP-1559 priority fee per gas in wei (default: estimated)
    # @option tx [Integer] :gas_price gas price in wei; builds a legacy (type 0) transaction instead of
    #   EIP-1559
    # @option tx [String] :from ignored, the sender is always the wallet
    # @option tx [Integer, Symbol, String] :block ignored by writes
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [BlockGiven::Transaction] handle on the broadcast transaction (`#wait!` polls the receipt)
    # @raise [BlockGiven::WalletRequiredError] when the instance has no wallet
    # @raise [BlockGiven::InvalidArgumentError] when `value:` is given for a non-payable function, on
    #   unknown `tx:` keys or malformed arguments
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::ContractRevertError] when gas estimation or broadcast reverts; custom errors are
    #   decoded with the ABI
    # @example
    #   tx = usdc.write(:transfer, to: recipient, value: 1_000_000)
    #   tx.wait!
    def write(name, *args, tx: {}, **kwargs)
      prepare_write(name, *args, tx: tx, **kwargs).broadcast
    end

    # Signs a function call without broadcasting it.
    #
    # The returned {BlockGiven::SignedTransaction} knows its `#hash` and `#nonce` before any network call:
    # persist them, then call `#broadcast`. The signed transaction keeps this contract's ABI, so reverts
    # raised by `#broadcast` are decoded too. The sender is always the wallet: `from:` and `block:` are
    # validated but ignored.
    #
    # @param name [String, Symbol, Abi::Function] function name (snake_case or camelCase), full signature
    #   or an already resolved {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param tx [Hash] transaction overrides; keys must belong to {TX_OPTIONS}
    # @option tx [Integer] :value wei to send along, payable functions only (default: 0)
    # @option tx [Integer] :gas gas limit (default: estimated by the wallet)
    # @option tx [Integer] :nonce nonce to use (default: the wallet's pending nonce)
    # @option tx [Integer] :max_fee_per_gas EIP-1559 max fee per gas in wei (default: estimated)
    # @option tx [Integer] :max_priority_fee_per_gas EIP-1559 priority fee per gas in wei (default: estimated)
    # @option tx [Integer] :gas_price gas price in wei; builds a legacy (type 0) transaction instead of
    #   EIP-1559
    # @option tx [String] :from ignored, the sender is always the wallet
    # @option tx [Integer, Symbol, String] :block ignored by writes
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [BlockGiven::SignedTransaction] the signed, not yet broadcast transaction
    # @raise [BlockGiven::WalletRequiredError] when the instance has no wallet
    # @raise [BlockGiven::InvalidArgumentError] when `value:` is given for a non-payable function, on
    #   unknown `tx:` keys or malformed arguments
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::ContractRevertError] when gas estimation reverts; custom errors are decoded with
    #   the ABI
    # @example Persist the hash before broadcasting
    #   signed = registry.prepare_write(:record, movement_id, tx: { nonce: call.nonce })
    #   call.update!(tx_hash: signed.hash, nonce: signed.nonce, status: :submitted)
    #   signed.broadcast   # => BlockGiven::Transaction
    def prepare_write(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      unless wallet
        raise WalletRequiredError,
              "#{self.class.name}##{function.ruby_name} needs a wallet (pass wallet: to .new)"
      end

      options = tx_options(tx)
      value = options[:value] || 0
      if value != 0 && !function.payable?
        raise InvalidArgumentError, "#{function.name} is not payable, cannot send value"
      end

      data = function.encode(args, kwargs)
      with_decoded_errors do
        wallet.signed_transaction(
          to: address, data: data, value: value, gas: options[:gas], nonce: options[:nonce],
          max_fee_per_gas: options[:max_fee_per_gas], max_priority_fee_per_gas: options[:max_priority_fee_per_gas],
          gas_price: options[:gas_price]
        ).with_interface(interface)
      end
    end

    # Dry-runs a function with `eth_call` (from the wallet address by default) and returns the decoded
    # result.
    #
    # Nothing is signed or broadcast. `from:`, `value:`, `gas:` and `block:` are forwarded to the call;
    # the fee and nonce keys are validated but ignored. Unlike {#prepare_write}, `value:` is not checked
    # against the function's mutability.
    #
    # @param name [String, Symbol, Abi::Function] function name (snake_case or camelCase), full signature
    #   or an already resolved {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param tx [Hash] call overrides; keys must belong to {TX_OPTIONS}
    # @option tx [String] :from address used as `msg.sender` (default: the wallet address, when any)
    # @option tx [Integer] :value wei sent with the simulated call
    # @option tx [Integer] :gas gas limit of the simulated call
    # @option tx [Integer, Symbol, String] :block block number or tag the call is evaluated at
    #   (default: `:latest`)
    # @option tx [Integer] :nonce accepted for uniformity, ignored by simulations
    # @option tx [Integer] :max_fee_per_gas accepted for uniformity, ignored by simulations
    # @option tx [Integer] :max_priority_fee_per_gas accepted for uniformity, ignored by simulations
    # @option tx [Integer] :gas_price accepted for uniformity, ignored by simulations
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [Object, Array<Object>] the decoded output: a single value, or an Array for several outputs
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::InvalidArgumentError] on unknown `tx:` keys or malformed arguments
    # @raise [BlockGiven::ContractRevertError] when the call reverts, with the reason decoded
    #   (`Error(string)`, `Panic` or an ABI custom error)
    # @example
    #   begin
    #     usdc.simulate(:transfer, to: recipient, value: 1_000_000)
    #   rescue BlockGiven::ContractRevertError => e
    #     e.error_name # => "ERC20InsufficientBalance"
    #     e.args       # => { sender: "0x...", balance: 0, needed: 1000000 }
    #   end
    def simulate(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      options = tx_options(tx)
      data = function.encode(args, kwargs)
      raw = with_decoded_errors do
        client.call(to: address, data: data, from: options[:from] || wallet&.address, value: options[:value],
                    gas: options[:gas], block: options[:block] || :latest)
      end
      function.decode_output(raw)
    end

    # Estimates the gas needed by a function call with `eth_estimateGas`.
    #
    # `from:` and `value:` are forwarded to the estimation; the other {TX_OPTIONS} keys are validated but
    # ignored.
    #
    # @param name [String, Symbol, Abi::Function] function name (snake_case or camelCase), full signature
    #   or an already resolved {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param tx [Hash] call overrides; keys must belong to {TX_OPTIONS}
    # @option tx [String] :from address used as `msg.sender` (default: the wallet address, when any)
    # @option tx [Integer] :value wei sent with the estimated call
    # @option tx [Integer] :gas accepted for uniformity, ignored by estimations
    # @option tx [Integer] :nonce accepted for uniformity, ignored by estimations
    # @option tx [Integer] :max_fee_per_gas accepted for uniformity, ignored by estimations
    # @option tx [Integer] :max_priority_fee_per_gas accepted for uniformity, ignored by estimations
    # @option tx [Integer] :gas_price accepted for uniformity, ignored by estimations
    # @option tx [Integer, Symbol, String] :block accepted for uniformity, ignored by estimations
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [Integer] the estimated gas
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::InvalidArgumentError] on unknown `tx:` keys or malformed arguments
    # @raise [BlockGiven::ContractRevertError] when the estimated call reverts; custom errors are decoded
    #   with the ABI
    # @example
    #   usdc.estimate_gas(:transfer, to: recipient, value: 1_000_000) # => 51_234
    def estimate_gas(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      options = tx_options(tx)
      data = function.encode(args, kwargs)
      with_decoded_errors do
        client.estimate_gas(to: address, data: data, from: options[:from] || wallet&.address, value: options[:value])
      end
    end

    # ABI-encodes a function call (selector + arguments) without sending anything.
    #
    # @param name [String, Symbol, Abi::Function] function name, full signature or {Abi::Function}
    # @param args [Array] positional ABI inputs (exclusive with `kwargs`)
    # @param kwargs [Hash] ABI inputs by snake_cased name (exclusive with `args`)
    # @return [String] `0x`-prefixed calldata
    # @raise [BlockGiven::FunctionNotFoundError] when the name (or overload) is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match
    # @raise [BlockGiven::InvalidArgumentError] when the arguments do not match the ABI inputs
    # @raise [BlockGiven::AbiError] when the ABI encoder rejects a value
    def encode_function_data(name, *args, **kwargs)
      resolve(name, args, kwargs).encode(args, kwargs)
    end

    # Decodes the raw return data of a function call.
    #
    # @param name [String, Symbol] function name or full signature; overloads must be given as a signature
    # @param hex [String] the `0x`-prefixed return data
    # @return [Object, Array<Object>] a single decoded value, or an Array for several outputs
    # @raise [BlockGiven::FunctionNotFoundError] when the name is not in the ABI
    # @raise [BlockGiven::AmbiguousFunctionError] when the name is overloaded
    # @raise [BlockGiven::AbiError] when the data is empty or cannot be decoded
    def decode_function_result(name, hex)
      interface.function(name).decode_output(hex)
    end

    # --- Events -------------------------------------------------------------

    # Fetches past events emitted by this contract and decodes them.
    #
    # @param name [String, Symbol, nil] event name (snake_case or camelCase) or signature; `nil` fetches
    #   every log of the contract (logs with a topic unknown to the ABI are skipped)
    # @param from_block [Integer, Symbol, String] first block of the range (number or tag)
    # @param to_block [Integer, Symbol, String] last block of the range (default: `:latest`)
    # @param args [Hash] filters on indexed parameters, by snake_cased name: `nil` is a wildcard, an Array
    #   matches any of its values (see {Abi::Event#encode_topics})
    # @param max_block_range [Integer, nil] split the range into several `eth_getLogs` calls of at most
    #   this many blocks (providers cap the range)
    # @return [Array<BlockGiven::Event>] decoded events, oldest first
    # @raise [BlockGiven::EventNotFoundError] when `name` is not an event of the ABI
    # @raise [BlockGiven::InvalidArgumentError] when `args` names a non-indexed parameter
    # @raise [BlockGiven::RpcError] when the node rejects the request
    # @example
    #   usdc.get_events(:Transfer, from_block: 18_000_000, to_block: :latest, args: { to: wallet.address })
    #   usdc.get_events(from_block: 18_000_000, max_block_range: 2_000) # every known event, chunked
    def get_events(name = nil, from_block:, to_block: :latest, args: {}, max_block_range: nil)
      topics = name ? interface.event(name).encode_topics(args) : nil
      logs = if max_block_range
               client.get_logs_in_chunks(address: address, topics: topics, from_block: from_block,
                                         to_block: to_block, max_block_range: max_block_range)
             else
               client.get_logs(address: address, topics: topics, from_block: from_block, to_block: to_block)
             end
      decode_logs(logs)
    end

    # Polls for new events in a background thread and yields each decoded event.
    #
    # Resuming after a restart: pass `from_block:` (your persisted cursor + 1) and persist the `to` block
    # handed to `on_progress` after each processed range. `confirmations:` keeps the watcher N blocks
    # behind the head so reorged logs are never delivered. The watcher is registered by id and can be
    # stopped with `watcher.stop` or `BlockGiven::Watcher.stop(id)`.
    #
    # @param name [String, Symbol, nil] event name or signature; `nil` watches every event known to the ABI
    # @param args [Hash] filters on indexed parameters, by snake_cased name (see {Abi::Event#encode_topics})
    # @param from_block [Integer, nil] first block to process (default: start from the current head)
    # @param polling_interval [Numeric, nil] seconds between ticks (default: the client's interval)
    # @param max_block_range [Integer, nil] maximum blocks per `eth_getLogs` call while catching up
    #   (default: `BlockGiven.config.max_block_range`)
    # @param confirmations [Integer] number of blocks to stay behind the head (default: 0)
    # @param on_progress [#call, nil] called with `(from, to)` after each processed block range
    # @param id [String, nil] stable watcher id for `BlockGiven::Watcher.find` / `.stop`
    #   (default: generated)
    # @yield [event] once per decoded event, in log order, from the watcher thread
    # @yieldparam event [BlockGiven::Event] the decoded event
    # @return [BlockGiven::Watcher] the started watcher
    # @raise [ArgumentError] when no block is given
    # @raise [BlockGiven::EventNotFoundError] when `name` is not an event of the ABI
    # @raise [BlockGiven::InvalidArgumentError] when `args` names a non-indexed parameter, or when a
    #   watcher with the same `id` is already running
    # @example
    #   watcher = usdc.watch_event(:Transfer, args: { to: me }) { |event| puts event.args }
    #   watcher.stop
    # @example Resumable watcher
    #   usdc.watch_event(:Transfer, from_block: cursor.last_block + 1, confirmations: 3,
    #                    on_progress: ->(_from, to) { cursor.update!(last_block: to) }) do |event|
    #     Deposit.record!(event)
    #   end
    def watch_event(name = nil, args: {}, from_block: nil, polling_interval: nil, max_block_range: nil,
                    confirmations: 0, on_progress: nil, id: nil, &block)
      raise ::ArgumentError, "a block is required" unless block

      event = name && interface.event(name)
      topics = event&.encode_topics(args)
      label = "#{event ? event.name : '*'}@#{self.class.name || 'Contract'}(#{address[0, 10]})"
      client.watch_logs(address: address, topics: topics, from_block: from_block,
                        polling_interval: polling_interval, max_block_range: max_block_range,
                        confirmations: confirmations, on_progress: on_progress, id: id, name: label) do |logs|
        decode_logs(logs).each { |event| block.call(event) }
      end
    end
    alias watch_events watch_event

    # Decodes raw logs with this contract's ABI.
    #
    # Logs are normalized first when they are not already snake_case Hashes. Logs whose first topic does
    # not match an event of the ABI are skipped. The log address is not checked; use {#events_from} for
    # that.
    #
    # @param logs [Array<Hash>] raw JSON-RPC logs or normalized log Hashes (with `:topics` and `:data`)
    # @return [Array<BlockGiven::Event>] the decoded events, in input order
    # @raise [BlockGiven::AbiError] when a matching log carries data that cannot be decoded
    # @example
    #   usdc.decode_logs(receipt.logs)
    def decode_logs(logs)
      logs.filter_map do |log|
        log = Normalizer.normalize(log) unless log.is_a?(Hash) && log.key?(:topics)
        topic = Array(log[:topics]).first
        event = topic && interface.event_by_topic(topic)
        event&.decode(log)
      end
    end

    # Decodes the events emitted by this contract in a transaction receipt.
    #
    # Logs emitted by other addresses are ignored.
    #
    # @param receipt [BlockGiven::Receipt, Hash] a receipt object responding to `#logs`, or a normalized
    #   receipt Hash with a `:logs` key
    # @return [Array<BlockGiven::Event>] the decoded events, in log order
    # @example
    #   tx = usdc.transfer(to: recipient, value: 1_000_000)
    #   usdc.events_from(tx.wait!).map(&:name) # => ["Transfer"]
    def events_from(receipt)
      logs = receipt.respond_to?(:logs) ? receipt.logs : Array(receipt[:logs])
      decode_logs(logs.select { |l| Utils.same_address?(l[:address], address) })
    end

    # Block explorer URL of this contract on its chain.
    #
    # @return [String, nil] `nil` when the chain has no explorer configured
    def explorer_url = chain.explorer_address_url(address)

    # Two contracts are equal when they share the same class and address (the wallet is not compared).
    #
    # @param other [Object]
    # @return [Boolean]
    def ==(other) = other.class == self.class && other.address == address

    # Compact representation showing the class, the address and the wallet address (never its key).
    #
    # @return [String]
    def inspect = "#<#{self.class.name} #{address}#{" wallet=#{wallet.address}" if wallet}>"

    private

    # Resolves a name, signature or Function into an Abi::Function using the call arguments for overloads.
    def resolve(name, args, kwargs)
      name.is_a?(Abi::Function) ? name : interface.function(name, args: args, kwargs: kwargs)
    end

    # Validates the tx: Hash against TX_OPTIONS and returns it with symbol keys.
    def tx_options(tx)
      raise InvalidArgumentError, "tx: must be a Hash" unless tx.is_a?(Hash)

      options = tx.transform_keys(&:to_sym)
      unknown = options.keys - TX_OPTIONS
      unless unknown.empty?
        raise InvalidArgumentError,
              "unknown tx option(s): #{unknown.join(', ')} (allowed: #{TX_OPTIONS.join(', ')})"
      end

      options
    end

    # Re-raises ContractRevertError enriched with custom errors decoded from this contract's ABI.
    def with_decoded_errors
      yield
    rescue ContractRevertError => e
      raise e.decode_with(interface)
    end
  end
end
