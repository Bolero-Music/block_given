# frozen_string_literal: true

require "json"

module BlockGiven
  # ABI layer: parsed interfaces, functions, events, custom errors, parameters and value coercion.
  #
  # {Abi::Interface.parse} turns an ABI (Array, artifact Hash, JSON String or file) into typed objects
  # that {BlockGiven::Contract} relies on to encode calls, decode outputs and logs, and name reverts.
  module Abi
    # Parsed ABI: functions (with overload resolution), events and custom errors.
    #
    # Functions are grouped by snake_case Ruby name so that overloads (`safeMint(address)` and
    # `safeMint(address,bytes)`) can be resolved from the call arguments or from a full signature.
    #
    # @example
    #   interface = BlockGiven::Abi::Interface.parse(File.read("abis/erc20.json"))
    #   interface.function(:balance_of).encode([owner])   # => "0x70a08231..."
    #   interface.event(:Transfer).topic                  # => "0xddf252ad..."
    #   interface.error_by_selector("0xe450d38c")         # => #<BlockGiven::Abi::CustomError ...>
    class Interface
      # @!attribute [r] functions
      #   @return [Array<Function>] every `function` definition, in ABI order
      # @!attribute [r] events
      #   @return [Array<Event>] every `event` definition, in ABI order
      # @!attribute [r] errors
      #   @return [Array<CustomError>] every `error` definition, in ABI order
      # @!attribute [r] constructor
      #   @return [Hash, nil] the raw `constructor` definition (String keys), or `nil` when the ABI has
      #     none; it is kept for reference only and cannot be encoded through this class
      # @!attribute [r] raw
      #   @return [Array<Hash>] the ABI definitions as given, with keys converted to Strings
      attr_reader :functions, :events, :errors, :constructor, :raw

      # Parses an ABI from any supported source.
      #
      # @param source [Array<Hash>, Hash, String, Pathname, File, Interface] an ABI Array, a Hardhat/Foundry
      #   artifact Hash with an `"abi"` (or `:abi`) key, a JSON String, a Pathname/File to read, or an
      #   Interface (returned as is)
      # @return [Interface]
      # @raise [BlockGiven::AbiError] when the JSON is invalid, the Hash has no `abi` key or the source
      #   type is not supported
      # @example
      #   BlockGiven::Abi::Interface.parse(JSON.parse(File.read("artifacts/Usdc.json")))
      #   BlockGiven::Abi::Interface.parse(Pathname.new("abis/erc20.json"))
      #   BlockGiven::Abi::Interface.parse([{ "type" => "function", "name" => "decimals", ... }])
      def self.parse(source)
        return source if source.is_a?(Interface)

        new(load_definitions(source))
      end

      # Turns a source accepted by {.parse} into an Array of raw ABI definitions.
      #
      # @api private
      # @param source [Array<Hash>, Hash, String, Pathname, File] see {.parse}
      # @return [Array<Hash>] the ABI definitions
      # @raise [BlockGiven::AbiError] when the source cannot be turned into an ABI Array
      def self.load_definitions(source)
        case source
        when Array then source
        when Hash then source["abi"] || source[:abi] || raise(AbiError, "Hash has no 'abi' key")
        when Pathname, File then load_definitions(JSON.parse(File.read(source)))
        when String then load_definitions(JSON.parse(source))
        else raise AbiError, "cannot parse ABI from #{source.class}"
        end
      rescue JSON::ParserError => e
        raise AbiError, "invalid ABI JSON: #{e.message}"
      end

      # Builds an interface from raw ABI definitions; prefer {.parse}.
      #
      # Definitions typed `function` (or without a `type`, as in very old ABIs) become {Function}s,
      # `event` become {Event}s, `error` become {CustomError}s and the `constructor` is kept raw.
      # Other types (`fallback`, `receive`) are ignored.
      #
      # @param definitions [Array<Hash>] ABI definitions with String or Symbol keys
      def initialize(definitions)
        @raw = definitions.map { |d| d.transform_keys(&:to_s) }
        @functions = []
        @events = []
        @errors = []
        @constructor = nil
        @raw.each do |definition|
          case definition["type"]
          when "function", nil then @functions << Function.new(definition)
          when "event" then @events << Event.new(definition)
          when "error" then @errors << CustomError.new(definition)
          when "constructor" then @constructor = definition
          end
        end
        @functions_by_name = @functions.group_by(&:ruby_name)
      end

      # Distinct snake_case function names (overloads share one name).
      #
      # @return [Array<Symbol>]
      def function_names = @functions_by_name.keys

      # Finds a function by name or full signature, resolving overloads from the call arguments.
      #
      # `name` may be snake_case or camelCase, or a full signature such as `"transfer(address,uint256)"`
      # (spaces are ignored). When several functions share the name, the overload is chosen by positional
      # arity (`args.size`) or by the set of snake_cased keyword names (`kwargs.keys`).
      #
      # @param name [String, Symbol] function name or signature
      # @param args [Array] positional arguments of the intended call, used to pick an overload by arity
      # @param kwargs [Hash] keyword arguments of the intended call, used to pick an overload by names
      # @return [Function]
      # @raise [BlockGiven::FunctionNotFoundError] when no function has this name or signature, or when
      #   no overload matches the given arguments
      # @raise [BlockGiven::AmbiguousFunctionError] when several overloads match the arguments
      # @example
      #   interface.function(:balance_of)
      #   interface.function("balanceOf")
      #   interface.function(:safe_mint, args: [to, data])              # overload by arity
      #   interface.function(:safe_mint, kwargs: { to: to, data: data })  # overload by keyword names
      #   interface.function("safeMint(address,bytes)")                  # explicit signature
      def function(name, args: [], kwargs: {})
        name = name.to_s
        return function_by_signature(name) if name.include?("(")

        candidates = @functions_by_name[Utils.snake_case(name).to_sym]
        if candidates.nil?
          raise FunctionNotFoundError,
                "no function #{name.inspect} in ABI (known: #{function_names.join(', ')})"
        end
        return candidates.first if candidates.size == 1

        matching =
          if kwargs.empty?
            candidates.select { |f| f.inputs.size == args.size }
          else
            keys = kwargs.keys.map { |k| Utils.snake_case(k).to_sym }.sort
            candidates.select { |f| f.input_names.sort == keys }
          end
        return matching.first if matching.size == 1

        if matching.size > 1
          raise AmbiguousFunctionError,
                "#{name} is overloaded, use the full signature: #{candidates.map(&:signature).join(' | ')}"
        end
        raise FunctionNotFoundError,
              "no overload of #{name} matches the given arguments (#{candidates.map(&:signature).join(' | ')})"
      end

      # Finds a function by its exact canonical signature.
      #
      # @param signature [String] for example `"transfer(address,uint256)"`; spaces are removed
      # @return [Function]
      # @raise [BlockGiven::FunctionNotFoundError] when no function has this signature
      def function_by_signature(signature)
        @functions.find { |f| f.signature == signature.delete(" ") } ||
          raise(FunctionNotFoundError, "no function with signature #{signature.inspect}")
      end

      # Finds a function by its 4-byte selector.
      #
      # @param selector [String] `0x`-prefixed 4-byte selector, any case
      # @return [Function, nil] `nil` when unknown
      def function_by_selector(selector)
        @functions.find { |f| f.selector == selector.downcase }
      end

      # Finds an event by name (snake_case or camelCase) or by full signature.
      #
      # @param name [String, Symbol] for example `:Transfer`, `:transfer` or `"Transfer(address,address,uint256)"`
      # @return [Event]
      # @raise [BlockGiven::EventNotFoundError] when the ABI has no such event
      def event(name)
        name = name.to_s
        key = Utils.snake_case(name).to_sym
        @events.find { |e| e.ruby_name == key || e.signature == name } ||
          raise(EventNotFoundError, "no event #{name.inspect} in ABI (known: #{@events.map(&:name).join(', ')})")
      end

      # Finds a non-anonymous event by its `topics[0]` hash.
      #
      # @param topic [String] `0x`-prefixed 32-byte keccak hash of the event signature, any case
      # @return [Event, nil] `nil` when unknown
      def event_by_topic(topic)
        @events.find { |e| e.topic == topic.to_s.downcase }
      end

      # Finds a custom error by its 4-byte selector (the first 4 bytes of revert data).
      #
      # @param selector [String] `0x`-prefixed 4-byte selector, any case
      # @return [CustomError, nil] `nil` when unknown
      def error_by_selector(selector)
        @errors.find { |e| e.selector == selector.to_s.downcase }
      end

      # Compact representation with the number of functions, events and errors.
      #
      # @return [String]
      def inspect
        "#<BlockGiven::Abi::Interface functions=#{@functions.size} events=#{@events.size} errors=#{@errors.size}>"
      end
    end
  end
end
