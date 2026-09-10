# frozen_string_literal: true

module Vium
  # Base class for typed contracts. Declare the ABI (and optionally a default
  # address / chain) and every ABI function becomes a Ruby method:
  #
  #   class Usdc < Vium::Contract
  #     abi_file "abis/erc20.json"   # your app's ABI file (see Vium.config.abi_path)
  #     address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  #   end
  #
  #   usdc = Usdc.new(wallet: Vium::Wallet.new(private_key: "0x..."))
  #   usdc.balance_of(wallet.address)                       # eth_call, decoded
  #   tx = usdc.transfer(to: "0x...", value: 1e6)           # signed + broadcast -> Vium::Transaction
  #   tx.wait!                                              # polls the receipt
  #
  # Transaction / call overrides go in the reserved `tx:` keyword:
  #   vault.deposit(amount, tx: { value: Vium::Utils.parse_ether("0.1"), gas: 200_000 })
  #   token.balance_of(addr, tx: { block: 18_000_000 })
  class Contract
    TX_OPTIONS = %i[value gas nonce max_fee_per_gas max_priority_fee_per_gas gas_price from block].freeze

    class << self
      attr_reader :interface

      # Sets (or returns) the ABI. Accepts an Array, an artifact Hash, or a JSON String.
      def abi(source = nil)
        return interface&.raw if source.nil?

        @interface = Abi::Interface.parse(source)
        define_abi_methods!
        @interface
      end

      # Loads the ABI from a JSON file. Relative paths are resolved against
      # Vium.config.abi_path when set (ABIs live in your app, not in the gem).
      def abi_file(path)
        base = Vium.config.abi_path
        path = File.join(base.to_s, path.to_s) if base && !File.absolute_path?(path.to_s)
        raise AbiError, "ABI file not found: #{path}" unless File.file?(path)

        abi(File.read(path))
      end

      # Default address for instances (can be overridden with .new(address: ...) / .at(...)).
      def address(value = nil)
        return @default_address if value.nil?

        @default_address = Utils.checksum_address(value)
      end
      alias default_address address

      def chain(value = nil)
        return @chain if value.nil?

        @chain = Chains.resolve(value)
      end

      def at(address, **options) = new(address: address, **options)

      def functions = interface&.functions || []
      def events = interface&.events || []
      def errors = interface&.errors || []

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@interface, @interface)
        subclass.instance_variable_set(:@default_address, @default_address)
        subclass.instance_variable_set(:@chain, @chain)
        subclass.send(:define_abi_methods!) if @interface
      end

      private

      # One Ruby method per ABI function name (snake_case). Names clashing with
      # existing methods (send, class, address...) are skipped: use #read / #write.
      def define_abi_methods!
        interface.function_names.each do |ruby_name|
          if Contract.method_defined?(ruby_name) || Contract.private_method_defined?(ruby_name)
            Vium.config.logger.debug { "[vium] #{name}: skipping ##{ruby_name} (reserved), use read/write" }
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

    attr_reader :address, :wallet

    def initialize(address: nil, wallet: nil, client: nil, chain: nil)
      raise AbiError, "#{self.class.name} has no ABI: declare it with `abi [...]` or `abi_file`" unless interface

      resolved = address || self.class.default_address
      raise InvalidArgumentError, "#{self.class.name}: address is required" if resolved.nil?

      @address = Utils.checksum_address(resolved)
      @wallet = wallet
      @client = client
      @chain = chain
    end

    def interface = self.class.interface

    def client
      @client ||= begin
        chain = @chain || self.class.chain
        if wallet && (chain.nil? || wallet.client.chain == Chains.resolve(chain))
          wallet.client
        elsif chain
          Client.new(chain: chain)
        else
          Vium.client
        end
      end
    end

    def chain = client.chain
    def with_wallet(wallet) = self.class.new(address: address, wallet: wallet, client: @client, chain: @chain)

    # --- Reads / writes -----------------------------------------------------

    # eth_call + decode. Overrides: tx: { block:, from: }.
    def read(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      data = function.encode(args, kwargs)
      options = tx_options(tx)
      raw = with_decoded_errors do
        client.call(to: address, data: data, from: options[:from] || wallet&.address, block: options[:block] || :latest)
      end
      function.decode_output(raw)
    end

    # Signs and broadcasts. Returns a Vium::Transaction. Overrides: tx: { value:, gas:, nonce:, fees... }.
    def write(name, *args, tx: {}, **kwargs)
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
        wallet.send_transaction(
          to: address, data: data, value: value, gas: options[:gas], nonce: options[:nonce],
          max_fee_per_gas: options[:max_fee_per_gas], max_priority_fee_per_gas: options[:max_priority_fee_per_gas],
          gas_price: options[:gas_price]
        )
      end
    end

    # Dry-runs a write with eth_call from the wallet address and returns the decoded
    # result. Raises Vium::ContractRevertError with the decoded reason on failure.
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

    def estimate_gas(name, *args, tx: {}, **kwargs)
      function = resolve(name, args, kwargs)
      options = tx_options(tx)
      data = function.encode(args, kwargs)
      with_decoded_errors do
        client.estimate_gas(to: address, data: data, from: options[:from] || wallet&.address, value: options[:value])
      end
    end

    def encode_function_data(name, *args, **kwargs)
      resolve(name, args, kwargs).encode(args, kwargs)
    end

    def decode_function_result(name, hex)
      interface.function(name).decode_output(hex)
    end

    # --- Events -------------------------------------------------------------

    # Fetches past events. `args` filters on indexed parameters.
    #   usdc.get_events(:Transfer, from_block: 18_000_000, to_block: :latest, args: { to: wallet.address })
    # Pass max_block_range: to split a large range into several eth_getLogs calls.
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

    # Polls for new events in a background thread. Returns a Vium::Watcher.
    #   watcher = usdc.watch_event(:Transfer, args: { to: me }) { |event| puts event.args }
    #   watcher.stop
    #
    # Resuming after a restart: pass from_block: (your persisted cursor + 1) and persist the
    # `to` block handed to on_progress after each processed range. confirmations: keeps the
    # watcher N blocks behind the head so reorged logs are never delivered.
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

    # Decodes raw logs with this contract's ABI. Unknown topics are skipped.
    def decode_logs(logs)
      logs.filter_map do |log|
        log = Normalizer.normalize(log) unless log.is_a?(Hash) && log.key?(:topics)
        topic = Array(log[:topics]).first
        event = topic && interface.event_by_topic(topic)
        event&.decode(log)
      end
    end

    # Events emitted by this contract in a receipt.
    def events_from(receipt)
      logs = receipt.respond_to?(:logs) ? receipt.logs : Array(receipt[:logs])
      decode_logs(logs.select { |l| Utils.same_address?(l[:address], address) })
    end

    def explorer_url = chain.explorer_address_url(address)
    def ==(other) = other.class == self.class && other.address == address
    def inspect = "#<#{self.class.name} #{address}#{" wallet=#{wallet.address}" if wallet}>"

    private

    def resolve(name, args, kwargs)
      name.is_a?(Abi::Function) ? name : interface.function(name, args: args, kwargs: kwargs)
    end

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

    def with_decoded_errors
      yield
    rescue ContractRevertError => e
      raise e.decode_with(interface)
    end
  end
end
