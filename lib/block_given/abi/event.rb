# frozen_string_literal: true

module BlockGiven
  module Abi
    # One ABI event: builds `eth_getLogs` topic filters and decodes logs into {BlockGiven::Event}s.
    #
    # @example
    #   transfer = interface.event(:Transfer)
    #   transfer.topic                                   # => "0xddf252ad..."
    #   transfer.encode_topics(to: wallet.address)       # => ["0xddf252ad...", nil, "0x000...wallet"]
    #   transfer.decode(log).args                        # => { from: "0x...", to: "0x...", value: 1000000 }
    class Event
      # @!attribute [r] name
      #   @return [String] the Solidity name (`"Transfer"`)
      # @!attribute [r] inputs
      #   @return [Array<Parameter>] the parameters, indexed and not, in declaration order
      # @!attribute [r] anonymous
      #   @return [Boolean] whether the event is declared `anonymous` (no signature topic)
      attr_reader :name, :inputs, :anonymous

      # Builds an event from its ABI definition.
      #
      # @param definition [Hash] the ABI entry (`"name"`, `"inputs"`, `"anonymous"`), String or Symbol keys
      def initialize(definition)
        definition = definition.transform_keys(&:to_s)
        @name = definition["name"].to_s
        @inputs = Array(definition["inputs"]).each_with_index.map { |i, idx| Parameter.new(i, index: idx) }
        @anonymous = !!definition["anonymous"]
      end

      # The snake_case Ruby name (`Transfer` becomes `:transfer`, `OwnershipTransferred` becomes
      # `:ownership_transferred`).
      #
      # @return [Symbol]
      def ruby_name = Utils.snake_case(name).to_sym

      # The canonical signature, with tuples expanded (`"Transfer(address,address,uint256)"`).
      #
      # @return [String]
      def signature = "#{name}(#{inputs.map(&:type).join(',')})"

      # The `topics[0]` value of the event: `keccak256(signature)`, `0x`-prefixed lowercase (memoized).
      #
      # @return [String]
      def topic = @topic ||= Utils.keccak256(signature)

      # Whether the event is anonymous (its logs carry no signature topic).
      #
      # @return [Boolean]
      def anonymous? = anonymous

      # Parameters declared `indexed`, in declaration order (they live in `topics[1..]`).
      #
      # @return [Array<Parameter>]
      def indexed_inputs = inputs.select(&:indexed?)

      # Parameters not declared `indexed`, in declaration order (they are ABI-encoded in `data`).
      #
      # @return [Array<Parameter>]
      def data_inputs = inputs.reject(&:indexed?)

      # Whether a log was emitted by this (non-anonymous) event, based on its first topic.
      #
      # @param log [Hash] a log with a `:topics` or `"topics"` key
      # @return [Boolean] always `false` for anonymous events
      def matches?(log)
        topic0 = Array(log[:topics] || log["topics"]).first
        !anonymous? && topic0&.downcase == topic
      end

      # Decodes a log into a {BlockGiven::Event}.
      #
      # Indexed parameters are read from the topics (after `topics[0]`, unless the event is anonymous)
      # and non-indexed ones from `data`. Arguments are keyed by snake_case name in declaration order.
      # Indexed parameters of dynamic type (`string`, `bytes`, arrays, dynamic tuples) cannot be
      # recovered: their keccak hash topic is kept as the value. A missing topic yields `nil`.
      #
      # @param log [Hash] a log Hash with `:topics` / `"topics"` and `:data` / `"data"` keys (a normalized
      #   log from {BlockGiven::Client} or a raw JSON-RPC log)
      # @return [BlockGiven::Event] the decoded event, keeping the original log
      # @raise [BlockGiven::AbiError] when `data` cannot be decoded against the non-indexed parameters
      # @example
      #   event = interface.event(:Transfer).decode(log)
      #   event.args         # => { from: "0x...", to: "0x...", value: 1000000 }
      #   event[:value]      # => 1000000
      #   event.block_number # => 18000000
      def decode(log)
        topics = Array(log[:topics] || log["topics"])
        data = log[:data] || log["data"] || "0x"
        indexed_topics = anonymous? ? topics : topics[1..] || []

        args = {}
        indexed_inputs.each_with_index do |param, i|
          args[param.ruby_name] = decode_topic(indexed_topics[i], param)
        end
        unless data_inputs.empty?
          Coder.decode(data_inputs, data).each_with_index do |value, i|
            args[data_inputs[i].ruby_name] = value
          end
        end
        # keep declaration order
        ordered = inputs.to_h { |p| [p.ruby_name, args[p.ruby_name]] }
        BlockGiven::Event.new(name: name, signature: signature, args: ordered, log: log)
      end

      # Builds the `topics` filter of `eth_getLogs` from indexed argument values.
      #
      # The first topic is {#topic} (omitted for anonymous events), followed by one entry per indexed
      # parameter: `nil` is a wildcard, a single value matches that value, an Array matches any of its
      # values (OR). Trailing wildcards are trimmed. Values are coerced with {Coder.encode}; dynamic types
      # (`string`, `bytes`, arrays, dynamic tuples) are hashed with keccak256 as the EVM does.
      #
      # @param filters [Hash{Symbol, String => Object, Array, nil}] values by indexed parameter name
      #   (snake_case or camelCase)
      # @return [Array<String, Array<String>, nil>] the topics filter
      # @raise [BlockGiven::InvalidArgumentError] when a key is not an indexed parameter, or when a value
      #   cannot be coerced
      # @raise [BlockGiven::InvalidAddressError] when an address value is malformed
      # @example
      #   transfer.encode_topics(to: me)              # => [topic, nil, "0x000...me"]
      #   transfer.encode_topics(from: [a, b])        # => [topic, ["0x000...a", "0x000...b"]]
      #   transfer.encode_topics                      # => [topic]
      def encode_topics(filters = {})
        normalized = filters.transform_keys { |k| Utils.snake_case(k).to_sym }
        unknown = normalized.keys - indexed_inputs.map(&:ruby_name)
        unless unknown.empty?
          indexed = indexed_inputs.map(&:ruby_name).join(", ")
          raise InvalidArgumentError, "#{name}: #{unknown.join(', ')} is not an indexed parameter (indexed: #{indexed})"
        end

        topics = indexed_inputs.map do |param|
          value = normalized[param.ruby_name]
          next nil if value.nil?

          value.is_a?(Array) ? value.map { |v| encode_topic(v, param) } : encode_topic(value, param)
        end
        topics = topics.reverse.drop_while(&:nil?).reverse # trailing wildcards are implicit
        anonymous? ? topics : [topic, *topics]
      end

      # The canonical signature (same as {#signature}).
      #
      # @return [String]
      def to_s = signature

      # Compact representation with the signature.
      #
      # @return [String]
      def inspect = "#<BlockGiven::Abi::Event #{signature}>"

      private

      # Decodes one indexed topic; dynamic types keep the hash since the value itself is not in the log.
      def decode_topic(topic, param)
        return nil if topic.nil?
        return topic if param.dynamic? # only the keccak hash of the value is available

        Coder.decode([param], topic).first
      end

      # Encodes one filter value as a 32-byte topic (keccak256 for dynamic types).
      def encode_topic(value, param)
        return Utils.keccak256(param.raw_type == "string" ? value.to_s : value) if param.dynamic?

        Utils.prefix_hex(Utils.strip_hex(Coder.encode([param], [value])))
      end
    end
  end
end
