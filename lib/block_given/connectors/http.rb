# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module BlockGiven
  module Connectors
    # Generic JSON-RPC 2.0 over HTTP(S) transport built on Net::HTTP, with retries and exponential backoff.
    #
    # Each request is a POST of a JSON body to the endpoint. Transient failures are retried up to `retries`
    # times, sleeping `retry_delay * 2**(attempt - 1)` seconds between attempts: HTTP statuses listed in
    # {RETRIABLE_STATUSES}, JSON-RPC error codes listed in {RETRIABLE_RPC_CODES} (never a
    # {ContractRevertError}) and the network exceptions listed in {RETRIABLE_EXCEPTIONS}. Anything else is
    # raised immediately as {HttpError} or {RpcError}.
    #
    # Endpoints frequently embed an API key in their path, so {#inspect}, log lines and error messages only
    # ever show the redacted form produced by {#redact} (scheme and host, never the path).
    #
    # @example Explicit endpoint (local node, Infura, QuickNode...)
    #   BlockGiven::Connectors::Http.new(url: "http://127.0.0.1:8545")
    #   BlockGiven::Connectors::Http.new(url: "https://mainnet.infura.io/v3/KEY", timeout: 10, retries: 5)
    # @example Public RPC of the chain
    #   BlockGiven::Connectors::Http.new # -> uses chain.rpc_urls.first of the chain passed on each request
    class Http < Base
      # HTTP status codes that trigger a retry (timeouts, rate limiting, server and gateway errors).
      RETRIABLE_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze
      # JSON-RPC error codes that trigger a retry: provider rate limit (-32005), internal error (-32603), 429.
      RETRIABLE_RPC_CODES = [-32_005, -32_603, 429].freeze # rate limited / internal error
      # Network-level exceptions that trigger a retry; they surface as {HttpError} once retries are exhausted.
      RETRIABLE_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
                              Errno::EHOSTUNREACH, EOFError, SocketError, OpenSSL::SSL::SSLError].freeze

      # @!attribute [r] url
      #   @return [String, nil] fixed endpoint, or nil when the endpoint comes from the chain's `rpc_urls`
      # @!attribute [r] headers
      #   @return [Hash{String => String}] request headers sent with every POST (`Content-Type`, `User-Agent`
      #     and the custom ones given to the constructor)
      # @!attribute [r] timeout
      #   @return [Numeric] seconds applied to the open, read and write timeouts of each HTTP request
      # @!attribute [r] retries
      #   @return [Integer] maximum number of retries after the first attempt
      # @!attribute [r] retry_delay
      #   @return [Numeric] base delay in seconds before the first retry; doubled on each further retry

      attr_reader :url, :headers, :timeout, :retries, :retry_delay

      # Builds an HTTP transport.
      #
      # @param url [String, nil] JSON-RPC endpoint. When nil, {#endpoint} falls back to the first `rpc_urls`
      #   entry of the chain given on each request.
      # @param headers [Hash{String => String}] extra headers merged over the defaults
      #   (`Content-Type: application/json`, `User-Agent: block_given/<version>`); may override them
      # @param timeout [Numeric] seconds for the open, read and write timeouts of each HTTP request
      # @param retries [Integer] number of retries after the first failed attempt (0 disables retrying)
      # @param retry_delay [Numeric] seconds slept before the first retry; each further retry doubles it
      # @param logger [Logger, nil] receives retry notices at debug level. Defaults to `BlockGiven.config.logger`.
      def initialize(url: nil, headers: {}, timeout: 30, retries: 3, retry_delay: 0.5, logger: nil)
        super()
        @url = url
        user_agent = "block_given/#{BlockGiven::VERSION}"
        @headers = { "Content-Type" => "application/json", "User-Agent" => user_agent }.merge(headers)
        @timeout = timeout
        @retries = retries
        @retry_delay = retry_delay
        @logger = logger
        @id = 0
        @mutex = Mutex.new
      end

      # Resolves the endpoint used for a request: the fixed `url`, or the chain's first public RPC url.
      #
      # @param chain [Chain, nil] chain being queried
      # @return [String] the endpoint URL (may contain credentials: pass it through {#redact} before logging)
      # @raise [ConfigurationError] when no `url` was given and the chain has no `rpc_urls`
      def endpoint(chain)
        return url if url

        chain&.rpc_urls&.first ||
          raise(ConfigurationError, "no RPC url: pass url: to the connector or use a chain with rpc_urls")
      end

      # Sends one JSON-RPC 2.0 request (with an auto-incremented id) and returns its `result`.
      #
      # Retriable failures are retried with exponential backoff, see the class description.
      #
      # @param method [String] JSON-RPC method name
      # @param params [Array<Object>] positional JSON-RPC params
      # @param chain [Chain, nil] chain being queried, used to resolve the endpoint when no `url` is fixed
      # @return [Object] the raw JSON-RPC `result`
      # @raise [ContractRevertError] when the node reports an EVM revert (never retried)
      # @raise [RpcError] when the node answers with a JSON-RPC error, or the body is not a JSON object;
      #   retriable codes are raised only once retries are exhausted
      # @raise [HttpError] on a non-2xx status, an invalid JSON body or a network error (after retries)
      # @raise [ConfigurationError] when no endpoint can be resolved
      def request(method, params = [], chain: nil)
        payload = { jsonrpc: "2.0", id: next_id, method: method, params: params }
        body = with_retries(method) { post(endpoint(chain), payload) }
        handle_single(body, method)
      end

      # Sends several calls in one JSON-RPC batch request (a single HTTP POST with an array body).
      #
      # Responses are matched to calls by id, so the node may answer in any order. A call whose response
      # carries an `error` (or is missing from the response) yields an {RpcError} instance in its slot instead
      # of raising. Only transport-level failures of the whole batch are retried.
      #
      # @param calls [Array<Array(String, Array)>] `[method, params]` pairs; a missing params entry means `[]`
      # @param chain [Chain, nil] chain being queried, used to resolve the endpoint when no `url` is fixed
      # @return [Array<Object, RpcError>] one raw result (or {RpcError}) per call, in call order; `[]` for
      #   an empty `calls` (no request is sent)
      # @raise [RpcError] when the node does not answer with a JSON array
      # @raise [HttpError] on a non-2xx status, an invalid JSON body or a network error (after retries)
      # @raise [ConfigurationError] when no endpoint can be resolved
      def batch(calls, chain: nil)
        return [] if calls.empty?

        payload = calls.map { |(method, params)| { jsonrpc: "2.0", id: next_id, method: method, params: params || [] } }
        body = with_retries("batch") { post(endpoint(chain), payload) }
        raise RpcError, "batch response is not an array: #{body.inspect}" unless body.is_a?(Array)

        by_id = body.to_h { |entry| [entry["id"], entry] }
        payload.map do |req|
          entry = by_id[req[:id]] || { "error" => { "message" => "missing response for id #{req[:id]}" } }
          if entry.key?("error")
            RpcError.from_payload(entry["error"], rpc_method: req[:method])
          else
            entry["result"]
          end
        end
      end

      # Short description showing the redacted endpoint (or `chain default`), never the full URL.
      #
      # @return [String]
      def inspect = "#<#{self.class.name} url=#{url ? redact(url).inspect : 'chain default'}>"

      # Endpoint as it may appear in logs and error messages.
      #
      # RPC URLs usually carry the API key in their path (Infura, QuickNode, ...), so only the scheme and the
      # host (plus a non-default port) are kept; a non-empty path is replaced by `/…`.
      #
      # @example
      #   connector.redact("https://mainnet.infura.io/v3/SECRET") # => "https://mainnet.infura.io/…"
      #   connector.redact("http://127.0.0.1:8545")               # => "http://127.0.0.1:8545"
      # @param endpoint [String, URI::Generic] URL to redact
      # @return [String] the redacted URL, or `"<invalid url>"` when it cannot be parsed
      def redact(endpoint)
        uri = URI.parse(endpoint.to_s)
        host = uri.port && uri.port != uri.default_port ? "#{uri.host}:#{uri.port}" : uri.host
        path = uri.path.to_s.delete_prefix("/").empty? ? "" : "/…"
        "#{uri.scheme}://#{host}#{path}"
      rescue URI::InvalidURIError
        "<invalid url>"
      end

      private

      def logger = @logger || BlockGiven.config.logger

      def next_id
        @mutex.synchronize { @id += 1 }
      end

      def handle_single(body, method)
        raise RpcError.new("unexpected JSON-RPC response: #{body.inspect}", rpc_method: method) unless body.is_a?(Hash)

        if body.key?("error")
          error = RpcError.from_payload(body["error"], rpc_method: method)
          raise error unless RETRIABLE_RPC_CODES.include?(error.code) && !error.is_a?(ContractRevertError)

          raise Retry, error
        end
        body["result"]
      end

      # Internal signal raised by {Http#handle_single} to retry on a retriable JSON-RPC error; the original
      # {RpcError} is re-raised once retries are exhausted.
      #
      # @api private
      class Retry < StandardError
        # The retriable JSON-RPC error that triggered the retry.
        #
        # @return [RpcError]
        attr_reader :cause_error

        # @param cause_error [RpcError] the retriable JSON-RPC error; its message becomes this error's message
        def initialize(cause_error)
          @cause_error = cause_error
          super(cause_error.message)
        end
      end

      def with_retries(method)
        attempt = 0
        loop do
          begin
            return yield
          rescue Retry => e
            raise e.cause_error if attempt >= retries
          rescue HttpError => e
            raise unless RETRIABLE_STATUSES.include?(e.status) && attempt < retries
          rescue *RETRIABLE_EXCEPTIONS => e
            raise HttpError, "#{e.class}: #{e.message}" unless attempt < retries
          end
          attempt += 1
          delay = retry_delay * (2**(attempt - 1))
          logger.debug { "[block_given] retrying #{method} (attempt #{attempt}/#{retries}) in #{delay}s" }
          sleep(delay)
        end
      end

      def post(endpoint, payload)
        uri = URI.parse(endpoint)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)

        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = JSON.generate(payload)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise HttpError.new("HTTP #{response.code} from #{redact(endpoint)}: #{response.body.to_s[0, 200]}",
                              status: response.code.to_i, body: response.body)
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise HttpError.new("invalid JSON from RPC endpoint: #{e.message}", body: response&.body)
      end
    end
  end
end
