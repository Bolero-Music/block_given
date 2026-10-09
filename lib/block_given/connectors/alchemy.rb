# frozen_string_literal: true

module BlockGiven
  module Connectors
    # Alchemy JSON-RPC connector, an {Http} transport whose endpoint is derived from the chain.
    #
    # The URL is `https://<chain.alchemy_network>.g.alchemy.com/v2/<api_key>`, so a single instance can
    # serve every Alchemy-supported network declared in {Chains} (`alchemy_network` set). Retries, backoff,
    # timeouts and headers behave exactly as in {Http}.
    #
    # The API key never leaks: {#inspect} shows only its first 4 characters and {#redact} strips it from any
    # endpoint that ends up in a log line or an error message.
    #
    # @example
    #   connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
    #   BlockGiven::Client.new(chain: :base, connector: connector).block_number
    #   connector.inspect # => "#<BlockGiven::Connectors::Alchemy api_key=abcd…>"
    class Alchemy < Http
      # @!attribute [r] api_key
      #   @return [String] the Alchemy API key (as a String); do not log it, use {#inspect} or {#redact}

      attr_reader :api_key

      # Builds an Alchemy transport. There is no `url:` argument: the endpoint is computed per chain.
      #
      # @param api_key [String, #to_s] Alchemy API key
      # @param timeout [Numeric] seconds for the open, read and write timeouts of each HTTP request
      # @param retries [Integer] number of retries after the first failed attempt
      # @param retry_delay [Numeric] seconds slept before the first retry; doubled on each further retry
      # @param logger [Logger, nil] receives retry notices at debug level. Defaults to `BlockGiven.config.logger`.
      # @param headers [Hash{String => String}] extra headers merged over the {Http} defaults
      # @raise [ConfigurationError] when `api_key` is nil or empty
      def initialize(api_key:, timeout: 30, retries: 3, retry_delay: 0.5, logger: nil, headers: {})
        raise ConfigurationError, "Alchemy api_key is required" if api_key.nil? || api_key.to_s.empty?

        @api_key = api_key.to_s
        super(url: nil, headers: headers, timeout: timeout, retries: retries, retry_delay: retry_delay, logger: logger)
      end

      # Alchemy endpoint for a chain: `https://<alchemy_network>.g.alchemy.com/v2/<api_key>`.
      #
      # @param chain [Chain] chain being queried; its `alchemy_network` (e.g. `"base-mainnet"`) selects the host
      # @return [String] the full endpoint URL, including the API key
      # @raise [ConfigurationError] when `chain` is nil or has no `alchemy_network`
      def endpoint(chain)
        raise ConfigurationError, "Alchemy connector needs a chain" if chain.nil?
        raise ConfigurationError, "#{chain.name} is not available on Alchemy" unless chain.alchemy_network

        "https://#{chain.alchemy_network}.g.alchemy.com/v2/#{api_key}"
      end

      # Short description with the API key masked (first 4 characters followed by an ellipsis).
      #
      # @return [String] e.g. `"#<BlockGiven::Connectors::Alchemy api_key=abcd…>"`
      def inspect = "#<BlockGiven::Connectors::Alchemy api_key=#{redacted_key}>"

      # Masks the API key inside an endpoint while keeping the network host visible.
      #
      # @example
      #   connector.redact(connector.endpoint(chain)) # => "https://base-mainnet.g.alchemy.com/v2/abcd…"
      # @param endpoint [String, #to_s] URL possibly containing the API key
      # @return [String] the URL with every occurrence of the key replaced by its masked form
      def redact(endpoint) = endpoint.to_s.sub(api_key, redacted_key)

      private

      def redacted_key = "#{api_key[0, 4]}…"
    end
  end
end
