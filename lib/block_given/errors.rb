# frozen_string_literal: true

module BlockGiven
  # Base class for every error raised by BlockGiven; rescue it to catch anything coming out of the gem.
  class Error < StandardError; end

  # Raised when the global configuration is missing or invalid: no connector, no chain, no RPC URL, a chain
  # unknown to {Chains.resolve}, or a chain Alchemy does not serve.
  class ConfigurationError < Error; end

  # Raised when a method receives a value it cannot use: malformed hex or decimal, unknown block tag,
  # unexpected keyword on a contract method, duplicate or unknown watcher id.
  class InvalidArgumentError < Error; end

  # Raised when a value is not a 20-byte `0x` hex address (see {Utils.checksum_address}).
  class InvalidAddressError < InvalidArgumentError; end

  # Raised when a contract write (or its preparation) is attempted on a contract without a wallet.
  class WalletRequiredError < Error; end

  # Raised when a blocking poll, such as waiting for a transaction receipt, exceeds its timeout.
  class TimeoutError < Error; end

  # Base class for ABI problems: missing or unreadable ABI file, unknown function or event.
  class AbiError < Error; end

  # Raised when an ABI has no function matching the requested name, signature or argument list.
  class FunctionNotFoundError < AbiError; end

  # Raised when an ABI has no event with the requested name.
  class EventNotFoundError < AbiError; end

  # Raised when a function name is overloaded and several overloads accept the given arguments; call it with the
  # full signature instead.
  class AmbiguousFunctionError < AbiError; end

  # Transport-level failure: non-2xx HTTP status, connection refused, invalid JSON body or exhausted retries.
  #
  # Endpoints in the message are redacted so API keys never leak into logs.
  #
  # @!attribute [r] status
  #   @return [Integer, nil] HTTP status code when the server answered, nil for connection failures
  # @!attribute [r] body
  #   @return [String, nil] raw response body when one was received (truncated in the message, complete here)
  class HttpError < Error
    attr_reader :status, :body

    # @param message [String] human readable description
    # @param status [Integer, nil] HTTP status code
    # @param body [String, nil] raw response body
    # @return [HttpError]
    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end
  end

  # JSON-RPC error object (`{ code, message, data }`) returned by the node for a request that reached it.
  #
  # Reverts are surfaced as the {ContractRevertError} subclass by {.from_payload}, which connectors use to turn
  # payloads into exceptions.
  #
  # @!attribute [r] code
  #   @return [Integer, nil] JSON-RPC error code (`-32000` for generic node errors, `3` for execution reverted)
  # @!attribute [r] data
  #   @return [String, Hash, nil] raw `error.data` field, untouched, as the provider returned it
  # @!attribute [r] rpc_method
  #   @return [String, nil] JSON-RPC method whose call failed (`"eth_call"`, `"eth_sendRawTransaction"`)
  class RpcError < Error
    attr_reader :code, :data, :rpc_method

    # @param message [String] `error.message` from the payload
    # @param code [Integer, nil] `error.code`
    # @param data [String, Hash, nil] `error.data`
    # @param rpc_method [String, nil] JSON-RPC method that was called
    # @return [RpcError]
    def initialize(message, code: nil, data: nil, rpc_method: nil)
      super(message)
      @code = code
      @data = data
      @rpc_method = rpc_method
    end

    # Build the most specific error for a JSON-RPC error payload.
    #
    # Payloads carrying `0x` revert bytes in `data` (or nested under `data.data`), or whose message mentions
    # "revert", become a {ContractRevertError} with the revert bytes attached; anything else becomes a plain
    # {RpcError}. A payload that is not a Hash is wrapped with its string form as message.
    #
    # @param error [Hash, Object] JSON-RPC `error` object with String keys `"code"`, `"message"` and `"data"`
    # @param rpc_method [String, nil] method that was called, kept on the error for context
    # @return [BlockGiven::RpcError, BlockGiven::ContractRevertError]
    # @example
    #   BlockGiven::RpcError.from_payload({ "code" => 3, "message" => "execution reverted", "data" => "0x08c3..." })
    #   # => #<BlockGiven::ContractRevertError: execution reverted: insufficient balance>
    def self.from_payload(error, rpc_method: nil)
      error = { "message" => error.to_s } unless error.is_a?(Hash)
      code = error["code"]
      message = error["message"].to_s
      data = error["data"]
      revert_data = extract_revert_data(data)

      if revert_data || message.match?(/revert/i)
        ContractRevertError.new(message, code: code, data: data, rpc_method: rpc_method, revert_data: revert_data)
      else
        new(message, code: code, data: data, rpc_method: rpc_method)
      end
    end

    # Extract the `0x` revert bytes from an error `data` field.
    #
    # Providers disagree on where the revert bytes live: Alchemy/geth put them in `data`, Hardhat/Anvil nest
    # them under `data.data`.
    #
    # @api private
    # @param data [String, Hash, nil] raw `error.data`
    # @return [String, nil] `0x` hex string, or nil when no revert bytes are present
    def self.extract_revert_data(data)
      case data
      when String then data.start_with?("0x") ? data : nil
      when Hash then extract_revert_data(data["data"] || data[:data])
      end
    end
  end

  # `eth_call`, `eth_estimateGas` or `eth_sendRawTransaction` rejected by the EVM with a revert.
  #
  # The message is rewritten to `"execution reverted: <reason>"` when the revert data is a Solidity
  # `Error(string)` or `Panic(uint256)`. Custom errors (`error InsufficientBalance(uint256)`) are decoded on
  # demand with {#decode_with} against a contract ABI; {Contract} and {SignedTransaction} do this automatically
  # before re-raising.
  #
  # @!attribute [r] revert_data
  #   @return [String, nil] ABI-encoded revert bytes as a `0x` hex string (4-byte selector followed by the
  #     encoded arguments), nil when the node returned none
  # @!attribute [r] error_name
  #   @return [String, nil] name of the custom error, set once decoded with {#decode_with}
  # @!attribute [r] args
  #   @return [Hash{Symbol => Object}, nil] custom error arguments keyed by snake_case name, set once decoded
  #     with {#decode_with}
  class ContractRevertError < RpcError
    # 4-byte selector of Solidity's built-in `Error(string)`, the revert with a reason string.
    ERROR_STRING_SELECTOR = "0x08c379a0"
    # 4-byte selector of Solidity's built-in `Panic(uint256)` (assertion failures, overflows, ...).
    PANIC_SELECTOR = "0x4e487b71"
    # Human readable description of each Solidity panic code carried by `Panic(uint256)`.
    PANIC_REASONS = {
      0x00 => "generic compiler inserted panic",
      0x01 => "assertion failed",
      0x11 => "arithmetic overflow or underflow",
      0x12 => "division or modulo by zero",
      0x21 => "invalid enum conversion",
      0x22 => "incorrectly encoded storage byte array",
      0x31 => "pop() on an empty array",
      0x32 => "array index out of bounds",
      0x41 => "too much memory allocated or array too large",
      0x51 => "call to a zero-initialized variable of internal function type"
    }.freeze

    attr_reader :revert_data, :error_name, :args

    # @param message [String] message from the RPC error payload; replaced by the decoded built-in reason when
    #   one is found and the original does not already contain it, or by `"execution reverted"` when empty
    # @param code [Integer, nil] JSON-RPC error code
    # @param data [String, Hash, nil] raw `error.data`
    # @param rpc_method [String, nil] JSON-RPC method that was called
    # @param revert_data [String, nil] `0x` revert bytes
    # @param error_name [String, nil] decoded custom error name (set by {#decode_with})
    # @param args [Hash{Symbol => Object}, nil] decoded custom error arguments (set by {#decode_with})
    # @return [ContractRevertError]
    def initialize(message, code: nil, data: nil, rpc_method: nil, revert_data: nil, error_name: nil, args: nil)
      @revert_data = revert_data
      @error_name = error_name
      @args = args
      super(build_message(message), code: code, data: data, rpc_method: rpc_method)
    end

    # Human readable revert reason when the revert data is a built-in `Error(string)` or `Panic(uint256)`.
    #
    # Memoised. Custom errors and undecodable data yield nil; use {#decode_with} for custom errors.
    #
    # @return [String, nil] the `Error(string)` text, or `"Panic(0x11): arithmetic overflow or underflow"`
    def reason
      return @reason if defined?(@reason)

      @reason = decode_builtin_reason
    end

    # 4-byte selector at the start of the revert data.
    #
    # @return [String, nil] `0x` followed by 8 hex chars, nil without revert data
    def selector
      revert_data && revert_data.length >= 10 ? revert_data[0, 10] : nil
    end

    # Whether the revert data is a custom error, i.e. its selector is neither `Error(string)` nor `Panic`.
    #
    # @return [Boolean]
    def custom_error?
      !selector.nil? && ![ERROR_STRING_SELECTOR, PANIC_SELECTOR].include?(selector)
    end

    # Return a copy of this error enriched with a custom error decoded from an ABI interface.
    #
    # @param interface [BlockGiven::Abi::Interface, nil] interface whose custom errors are matched by selector
    # @return [BlockGiven::ContractRevertError] a new error whose message is `Name(arg1, arg2)` with
    #   {#error_name} and {#args} set; `self` when the data is not a custom error, no interface is given or the
    #   interface does not know the selector
    # @example
    #   begin
    #     token.transfer(to, amount)
    #   rescue BlockGiven::ContractRevertError => e
    #     e.decode_with(token.interface).error_name # => "ERC20InsufficientBalance"
    #   end
    def decode_with(interface)
      return self unless custom_error? && interface

      custom = interface.error_by_selector(selector)
      return self unless custom

      decoded = custom.decode(revert_data)
      self.class.new(
        "#{custom.name}(#{decoded.values.map(&:inspect).join(', ')})",
        code: code, data: data, rpc_method: rpc_method, revert_data: revert_data,
        error_name: custom.name, args: decoded
      )
    end

    private

    def build_message(original)
      reason = decode_builtin_reason
      return "execution reverted: #{reason}" if reason && !original.include?(reason)

      original.empty? ? "execution reverted" : original
    end

    def decode_builtin_reason
      return nil unless revert_data && revert_data.length > 10

      payload = "0x#{revert_data[10..]}"
      case selector
      when ERROR_STRING_SELECTOR
        Eth::Abi.decode(["string"], payload).first
      when PANIC_SELECTOR
        panic_code = Eth::Abi.decode(["uint256"], payload).first
        "Panic(0x#{panic_code.to_s(16).rjust(2, '0')}): #{PANIC_REASONS.fetch(panic_code, 'unknown panic')}"
      end
    rescue StandardError
      nil
    end
  end

  # Raised by {Transaction#wait!} when the mined receipt has a failed status (`status == 0`).
  #
  # @!attribute [r] receipt
  #   @return [BlockGiven::Receipt] the mined receipt carrying the failed status
  class TransactionRevertedError < Error
    attr_reader :receipt

    # @param receipt [BlockGiven::Receipt] receipt whose `transaction_hash` and `block_number` build the message
    # @return [TransactionRevertedError]
    def initialize(receipt)
      @receipt = receipt
      super("transaction #{receipt.transaction_hash} reverted in block #{receipt.block_number}")
    end
  end
end
