# frozen_string_literal: true

require "json"

module BlockGiven
  module Abi
    # Parsed ABI: functions (with overload resolution), events and custom errors.
    class Interface
      attr_reader :functions, :events, :errors, :constructor, :raw

      # Accepts an ABI Array, a Hardhat/Foundry artifact Hash (with "abi"), a JSON String or a Pathname.
      def self.parse(source)
        return source if source.is_a?(Interface)

        new(load_definitions(source))
      end

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

      def function_names = @functions_by_name.keys

      # Finds a function by name (snake_case or camelCase) or by full signature
      # ("transfer(address,uint256)"). Overloads are disambiguated by argument
      # count or keyword names.
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

      def function_by_signature(signature)
        @functions.find { |f| f.signature == signature.delete(" ") } ||
          raise(FunctionNotFoundError, "no function with signature #{signature.inspect}")
      end

      def function_by_selector(selector)
        @functions.find { |f| f.selector == selector.downcase }
      end

      def event(name)
        name = name.to_s
        key = Utils.snake_case(name).to_sym
        @events.find { |e| e.ruby_name == key || e.signature == name } ||
          raise(EventNotFoundError, "no event #{name.inspect} in ABI (known: #{@events.map(&:name).join(', ')})")
      end

      def event_by_topic(topic)
        @events.find { |e| e.topic == topic.to_s.downcase }
      end

      def error_by_selector(selector)
        @errors.find { |e| e.selector == selector.to_s.downcase }
      end

      def inspect
        "#<BlockGiven::Abi::Interface functions=#{@functions.size} events=#{@events.size} errors=#{@errors.size}>"
      end
    end
  end
end
