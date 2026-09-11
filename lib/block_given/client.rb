# frozen_string_literal: true

module BlockGiven
  # Public JSON-RPC client bound to a chain and a connector (the equivalent of viem's PublicClient).
  #
  # Every method wrapping a JSON-RPC call returns Ruby values rather than raw JSON: QUANTITY fields are
  # decoded to Integer, object keys become snake_case Symbols ({Normalizer}), addresses are checksummed and
  # transactions / receipts are wrapped in {Transaction} / {Receipt}.
  #
  # Arguments named `block:` accept a block number (Integer), a hex QUANTITY string ("0x10"), or one of the
  # block tags `:latest`, `:earliest`, `:pending`, `:safe`, `:finalized` (Symbol or String); `nil` means
  # `latest`. See {Utils.block_tag}.
  #
  # @example Reading from Base through Alchemy
  #   connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV["ALCHEMY_API_KEY"])
  #   client = BlockGiven::Client.new(chain: :base, connector: connector)
  #   client.block_number       # => 12_345_678
  #   client.get_balance("0x...") # => 1_000_000_000_000_000_000 (wei)
  class Client
    # @!attribute [r] chain
    #   @return [Chain] the chain this client talks to (resolved from the constructor argument or the global config)
    # @!attribute [r] connector
    #   @return [Connectors::Base] the JSON-RPC transport used for every request

    attr_reader :chain, :connector

    # Builds a client. Every argument falls back to the global configuration ({BlockGiven.config}).
    #
    # @param chain [Chain, Symbol, String, Integer, nil] chain, symbol (`:base`), name ("base-sepolia") or chain id;
    #   resolved with {Chains.resolve}. Defaults to `BlockGiven.config.chain`.
    # @param connector [Connectors::Base, nil] JSON-RPC transport. Defaults to `BlockGiven.config.connector`.
    # @param polling_interval [Numeric, nil] seconds between two polls (receipts, watchers). Defaults to
    #   `BlockGiven.config.polling_interval`.
    # @param timeout [Numeric, nil] seconds before {#wait_for_transaction_receipt} gives up. Defaults to
    #   `BlockGiven.config.timeout`.
    # @param logger [Logger, nil] logger receiving debug lines for each RPC round trip. Defaults to
    #   `BlockGiven.config.logger`.
    # @raise [ConfigurationError] when no chain or no connector is given and none is configured globally
    def initialize(chain: nil, connector: nil, polling_interval: nil, timeout: nil, logger: nil)
      @chain = chain ? Chains.resolve(chain) : BlockGiven.config.chain!
      @connector = connector || BlockGiven.config.connector!
      @polling_interval = polling_interval
      @timeout = timeout
      @logger = logger
    end

    # Seconds between two polls, falling back to `BlockGiven.config.polling_interval`.
    #
    # @return [Numeric]
    def polling_interval = @polling_interval || BlockGiven.config.polling_interval

    # Seconds before a blocking wait gives up, falling back to `BlockGiven.config.timeout`.
    #
    # @return [Numeric]
    def timeout = @timeout || BlockGiven.config.timeout

    # Logger used for RPC debug lines and watcher warnings, falling back to `BlockGiven.config.logger`.
    #
    # @return [Logger]
    def logger = @logger || BlockGiven.config.logger

    # Performs a raw JSON-RPC call through the connector and returns the undecoded `result`.
    #
    # The method name and params are logged at debug level, as is the (truncated) result.
    #
    # @example
    #   client.request("eth_blockNumber")                   # => "0xbc614e"
    #   client.request("eth_getBalance", "0x...", "latest") # => "0xde0b6b3a7640000"
    # @param method [String] JSON-RPC method name
    # @param params [Array<Object>] positional JSON-RPC params, passed as-is
    # @return [Object] the JSON-RPC `result` (String, Hash, Array, nil...) as returned by the node
    # @raise [RpcError] when the node answers with a JSON-RPC error
    # @raise [HttpError] when the transport fails (non-2xx status, network error, invalid JSON)
    def request(method, *params)
      logger.debug { "[block_given] -> #{method} #{params.inspect}" }
      result = connector.request(method, params, chain: chain)
      logger.debug { "[block_given] <- #{method} #{result.inspect[0, 200]}" }
      result
    end

    # Sends several JSON-RPC calls at once through the connector ({Connectors::Base#batch}).
    #
    # @example
    #   client.batch([["eth_blockNumber"], ["eth_chainId"]]) # => ["0xbc614e", "0x2105"]
    # @param calls [Array<Array(String, Array)>] `[method, params]` pairs; params may be omitted
    # @return [Array<Object, RpcError>] one raw result per call, in order; a failed call is returned (not raised)
    #   as an {RpcError} instance
    # @raise [HttpError] when the whole batch request fails at the transport level
    def batch(calls) = connector.batch(calls, chain: chain)

    # --- Chain / blocks -----------------------------------------------------

    # Chain id reported by the node (`eth_chainId`).
    #
    # @return [Integer] the chain id, e.g. 8453 for Base
    def chain_id = Utils.hex_to_int(request("eth_chainId"))

    # Number of the most recent block (`eth_blockNumber`).
    #
    # @return [Integer] the current head block number
    def block_number = Utils.hex_to_int(request("eth_blockNumber"))

    # Fetches a block by number, tag or hash (`eth_getBlockByNumber`, or `eth_getBlockByHash` when `block`
    # is a 32-byte hex hash).
    #
    # @param block [Integer, Symbol, String] block number, hex QUANTITY, block tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`) or a 66-character `0x` block hash
    # @param include_transactions [Boolean] when true the `:transactions` key holds full transaction objects
    #   instead of transaction hashes
    # @return [Hash{Symbol => Object}, nil] the block with snake_case Symbol keys and Integer quantities
    #   (`:number`, `:timestamp`, `:gas_used`, `:gas_limit`, `:base_fee_per_gas`, ...), or nil when the node does
    #   not know the block
    # @raise [InvalidArgumentError] when `block` is neither a number, a known tag nor a hex string
    def get_block(block = :latest, include_transactions: false)
      method = Utils.hex?(block.to_s) && block.to_s.length == 66 ? "eth_getBlockByHash" : "eth_getBlockByNumber"
      raw = request(method, block_param(block), include_transactions)
      raw && Normalizer.normalize(raw)
    end

    # Legacy gas price suggested by the node (`eth_gasPrice`).
    #
    # @return [Integer] gas price in wei
    def gas_price = Utils.hex_to_int(request("eth_gasPrice"))

    # Priority fee (tip) suggested by the node (`eth_maxPriorityFeePerGas`).
    #
    # Not every node implements the method: on an {RpcError} the value falls back to 1 gwei.
    #
    # @return [Integer] max priority fee per gas in wei
    def max_priority_fee_per_gas
      Utils.hex_to_int(request("eth_maxPriorityFeePerGas"))
    rescue RpcError
      Utils.parse_gwei("1") # method not supported by every node
    end

    # Estimates EIP-1559 fees with viem's semantics: `max_fee_per_gas = baseFee * multiplier + priority fee`.
    #
    # The base fee comes from the latest block (`eth_getBlockByNumber`), falling back to `eth_gasPrice` on
    # chains without EIP-1559; the priority fee comes from {#max_priority_fee_per_gas}.
    #
    # @param base_fee_multiplier [Numeric, nil] safety margin applied to the base fee. Defaults to
    #   `BlockGiven.config.base_fee_multiplier` (1.2).
    # @return [Hash{Symbol => Integer}] `:base_fee_per_gas`, `:max_priority_fee_per_gas` and `:max_fee_per_gas`,
    #   all in wei
    def estimate_fees_per_gas(base_fee_multiplier: nil)
      multiplier = base_fee_multiplier || BlockGiven.config.base_fee_multiplier
      block = get_block(:latest)
      base_fee = block[:base_fee_per_gas] || gas_price
      priority = max_priority_fee_per_gas
      {
        base_fee_per_gas: base_fee,
        max_priority_fee_per_gas: priority,
        max_fee_per_gas: (base_fee * multiplier).ceil + priority
      }
    end

    # --- Accounts -----------------------------------------------------------

    # Native currency balance of an account (`eth_getBalance`).
    #
    # @param address [String, #address] `0x` address (checksummed before being sent), or an object responding
    #   to `address` such as a {Wallet} or a {Contract}
    # @param block [Integer, Symbol, String, nil] block number, hex QUANTITY or tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`)
    # @return [Integer] balance in wei
    # @raise [InvalidAddressError] when `address` is not a valid 20-byte hex address
    def get_balance(address, block: :latest)
      Utils.hex_to_int(request("eth_getBalance", Utils.checksum_address(address), Utils.block_tag(block)))
    end

    # Number of transactions sent from an account, i.e. its next nonce (`eth_getTransactionCount`).
    #
    # Defaults to the `pending` tag so that queued transactions are taken into account.
    #
    # @param address [String, #address] `0x` address (checksummed before being sent)
    # @param block [Integer, Symbol, String, nil] block number, hex QUANTITY or tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`)
    # @return [Integer] the transaction count
    # @raise [InvalidAddressError] when `address` is not a valid 20-byte hex address
    def get_transaction_count(address, block: :pending)
      Utils.hex_to_int(request("eth_getTransactionCount", Utils.checksum_address(address), Utils.block_tag(block)))
    end

    # Bytecode deployed at an address (`eth_getCode`).
    #
    # @param address [String, #address] `0x` address (checksummed before being sent)
    # @param block [Integer, Symbol, String, nil] block number, hex QUANTITY or tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`)
    # @return [String] the code as a `0x` hex string; `"0x"` when the address holds no code
    # @raise [InvalidAddressError] when `address` is not a valid 20-byte hex address
    def get_code(address, block: :latest)
      request("eth_getCode", Utils.checksum_address(address), Utils.block_tag(block))
    end

    # Whether an address holds bytecode at the latest block (see {#get_code}).
    #
    # @param address [String, #address] `0x` address
    # @return [Boolean] true for a contract, false for an externally owned account
    # @raise [InvalidAddressError] when `address` is not a valid 20-byte hex address
    def contract?(address) = get_code(address) != "0x"

    # Reads a raw storage slot of a contract (`eth_getStorageAt`).
    #
    # @param address [String, #address] contract address (checksummed before being sent)
    # @param slot [Integer, String] storage slot, as an Integer or a hex string
    # @param block [Integer, Symbol, String, nil] block number, hex QUANTITY or tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`)
    # @return [String] the 32-byte slot value as a `0x` hex string
    # @raise [InvalidAddressError] when `address` is not a valid 20-byte hex address
    # @raise [InvalidArgumentError] when `slot` is neither an Integer nor a String
    def get_storage_at(address, slot, block: :latest)
      request("eth_getStorageAt", Utils.checksum_address(address), Utils.to_hex(slot), Utils.block_tag(block))
    end

    # --- Calls --------------------------------------------------------------

    # Executes a read-only call against a contract (`eth_call`) and returns the raw ABI-encoded result.
    #
    # Higher-level decoding lives in {Contract}; use this when you already hold encoded calldata.
    #
    # @example Reading `totalSupply()` of an ERC20
    #   client.call(to: usdc_address, data: "0x18160ddd")
    #   # => "0x000000000000000000000000000000000000000000000000000001c6bf526340"
    # @param to [String, #address] contract address (checksummed before being sent)
    # @param data [String] ABI-encoded calldata as a hex string (`0x` prefix optional); omitted when empty
    # @param from [String, #address, nil] sender address, for calls whose result depends on `msg.sender`
    # @param value [Integer, nil] wei sent along with the call; omitted when nil or 0
    # @param gas [Integer, nil] gas limit for the call
    # @param block [Integer, Symbol, String, nil] block number, hex QUANTITY or tag (`:latest`, `:earliest`,
    #   `:pending`, `:safe`, `:finalized`)
    # @return [String] the return data as a `0x` hex string
    # @raise [ContractRevertError] when the EVM reverts (a subclass of {RpcError}, carrying the revert data)
    # @raise [RpcError] for any other JSON-RPC error
    # @raise [InvalidAddressError] when `to` or `from` is not a valid 20-byte hex address
    def call(to:, data:, from: nil, value: nil, gas: nil, block: :latest)
      request("eth_call", call_object(to: to, data: data, from: from, value: value, gas: gas), Utils.block_tag(block))
    end

    # Estimates the gas needed by a transaction (`eth_estimateGas`).
    #
    # @param to [String, #address] recipient / contract address (checksummed before being sent)
    # @param data [String, nil] ABI-encoded calldata as a hex string; omitted when nil or empty
    # @param from [String, #address, nil] sender address
    # @param value [Integer, nil] wei sent along with the transaction; omitted when nil or 0
    # @return [Integer] the estimated gas units
    # @raise [ContractRevertError] when the simulated execution reverts
    # @raise [RpcError] for any other JSON-RPC error
    # @raise [InvalidAddressError] when `to` or `from` is not a valid 20-byte hex address
    def estimate_gas(to:, data: nil, from: nil, value: nil)
      Utils.hex_to_int(request("eth_estimateGas", call_object(to: to, data: data, from: from, value: value)))
    end

    # --- Transactions -------------------------------------------------------

    # Broadcasts a signed transaction (`eth_sendRawTransaction`).
    #
    # @param raw [String] RLP-encoded signed transaction as a hex string (`0x` prefix optional)
    # @return [Transaction] handle on the broadcast transaction, bound to this client so it can `wait`
    # @raise [ContractRevertError] when the node rejects the transaction because it would revert
    # @raise [RpcError] for any other JSON-RPC error (nonce too low, underpriced, ...)
    def send_raw_transaction(raw)
      Transaction.new(request("eth_sendRawTransaction", Utils.prefix_hex(raw)), client: self)
    end

    # Wraps an already known transaction hash in a {Transaction} handle. No RPC call is made.
    #
    # @param hash [String] `0x` transaction hash
    # @return [Transaction] handle bound to this client
    def transaction(hash) = Transaction.new(hash, client: self)

    # Fetches a transaction object by hash (`eth_getTransactionByHash`).
    #
    # @param hash [String] `0x` transaction hash
    # @return [Hash{Symbol => Object}, nil] the transaction with snake_case Symbol keys and Integer quantities
    #   (`:nonce`, `:value`, `:gas`, `:block_number`, `:max_fee_per_gas`, ...; `:block_number` is nil while
    #   pending), or nil when the node does not know the hash
    def get_transaction(hash)
      raw = request("eth_getTransactionByHash", hash)
      raw && Normalizer.normalize(raw)
    end

    # Fetches the receipt of a mined transaction (`eth_getTransactionReceipt`).
    #
    # @param hash [String] `0x` transaction hash
    # @return [Receipt, nil] the receipt, or nil while the transaction is not mined (or unknown)
    def get_transaction_receipt(hash)
      raw = request("eth_getTransactionReceipt", hash)
      raw && Receipt.new(raw)
    end

    # Blocks until the transaction is mined and confirmed by `confirmations` blocks, then returns its receipt.
    #
    # Polls `eth_getTransactionReceipt` (and `eth_blockNumber` when more than one confirmation is required)
    # through {Poller.poll}. A transaction mined in the current head block has exactly 1 confirmation.
    # The receipt is returned whatever its status: check {Receipt#success?} or use {Transaction#wait!}.
    #
    # @example
    #   receipt = client.wait_for_transaction_receipt(tx.hash, confirmations: 3, timeout: 300)
    #   receipt.status # => :success
    # @param hash [String] `0x` transaction hash
    # @param confirmations [Integer, nil] blocks that must include or follow the transaction (1 = mined).
    #   Defaults to `BlockGiven.config.confirmations`.
    # @param timeout [Numeric, nil] seconds before giving up. Defaults to {#timeout}.
    # @param polling_interval [Numeric, nil] seconds between two polls. Defaults to {#polling_interval}.
    # @return [Receipt] the mined (and confirmed) receipt
    # @raise [TimeoutError] when the receipt is still missing or unconfirmed after `timeout` seconds
    def wait_for_transaction_receipt(hash, confirmations: nil, timeout: nil, polling_interval: nil)
      confirmations ||= BlockGiven.config.confirmations
      interval = polling_interval || self.polling_interval
      Poller.poll(interval: interval, timeout: timeout || self.timeout, description: "receipt of #{hash}") do
        receipt = get_transaction_receipt(hash)
        next nil unless receipt&.block_number
        next receipt if confirmations <= 1

        block_number - receipt.block_number + 1 >= confirmations ? receipt : nil
      end
    end

    # --- Logs ---------------------------------------------------------------

    # Fetches event logs matching a filter (`eth_getLogs`).
    #
    # Providers cap the block range a single `eth_getLogs` may span; use {#get_logs_in_chunks} for large
    # ranges and {Contract#get_events} to decode the logs against an ABI.
    #
    # @example Transfer logs of one contract over 100 blocks
    #   transfer = BlockGiven::Utils.keccak256("Transfer(address,address,uint256)")
    #   client.get_logs(address: usdc, topics: [transfer], from_block: 20_000_000, to_block: 20_000_099)
    #   # => [{ address: "0x...", topics: [...], data: "0x...", block_number: 20_000_001, log_index: 3, ... }]
    # @param address [String, #address, Array<String, #address>, nil] one or several contract addresses
    #   (each checksummed before being sent); nil matches every address
    # @param topics [Array<String, Array<String>, nil>, nil] positional topic filter as expected by the node:
    #   a `0x` 32-byte topic, an Array of alternatives (OR), or nil as a wildcard at that position
    # @param from_block [Integer, Symbol, String, nil] start of the range: block number, hex QUANTITY or tag
    #   (`:latest`, `:earliest`, `:pending`, `:safe`, `:finalized`); ignored when `block_hash` is given
    # @param to_block [Integer, Symbol, String, nil] end of the range (inclusive), same forms as `from_block`
    # @param block_hash [String, nil] restrict the query to a single block by hash instead of a block range
    # @return [Array<Hash{Symbol => Object}>] raw logs with snake_case Symbol keys: `:address`, `:topics`
    #   (Array of `0x` strings), `:data`, `:block_number`, `:transaction_index` and `:log_index` (Integer),
    #   `:block_hash`, `:transaction_hash` and `:removed`
    # @raise [InvalidAddressError] when an address is not a valid 20-byte hex address
    # @raise [InvalidArgumentError] when a block argument is neither a number, a known tag nor a hex string
    # @raise [RpcError] when the node rejects the filter (range too large, too many results, ...)
    def get_logs(address: nil, topics: nil, from_block: :latest, to_block: :latest, block_hash: nil)
      filter = {}
      filter[:address] = Array(address).map { |a| Utils.checksum_address(a) } if address
      filter[:address] = filter[:address].first if filter[:address]&.size == 1
      filter[:topics] = topics if topics
      if block_hash
        filter[:blockHash] = block_hash
      else
        filter[:fromBlock] = Utils.block_tag(from_block)
        filter[:toBlock] = Utils.block_tag(to_block)
      end
      Normalizer.normalize(request("eth_getLogs", filter))
    end

    # --- Watchers (background polling) --------------------------------------

    # Starts a background {Watcher} yielding the head block number as it advances (polls `eth_blockNumber`).
    #
    # The first tick yields the current head. Later ticks yield only when the head moved forward: by default
    # just the new head, with `emit_missed: true` every block number between the previous head (excluded) and
    # the new one (included), in order.
    #
    # @param polling_interval [Numeric, nil] seconds between two polls. Defaults to {#polling_interval}.
    # @param emit_missed [Boolean] yield every block skipped between two polls instead of only the latest one
    # @param id [String, nil] stable identifier for {Watcher.find} / {Watcher.stop}. Defaults to a generated one.
    # @yield [number] for each new block number, from the watcher thread
    # @yieldparam number [Integer] block number
    # @yieldreturn [void]
    # @return [Watcher] the started watcher; call {Watcher#stop} to end it
    # @raise [InvalidArgumentError] when a watcher with the same `id` is already running
    def watch_block_number(polling_interval: nil, emit_missed: false, id: nil, &block)
      last = nil
      watcher("block_number", polling_interval, id: id) do
        current = block_number
        next if last && current <= last

        if emit_missed && last
          ((last + 1)..current).each { |n| block.call(n) }
        else
          block.call(current)
        end
        last = current
      end
    end

    # Starts a background {Watcher} yielding every new block object (`eth_getBlockByNumber` for each block
    # number reported by {#watch_block_number} with `emit_missed: true`).
    #
    # @param polling_interval [Numeric, nil] seconds between two polls. Defaults to {#polling_interval}.
    # @param include_transactions [Boolean] when true blocks carry full transaction objects instead of hashes
    # @param id [String, nil] stable identifier for {Watcher.find} / {Watcher.stop}. Defaults to a generated one.
    # @yield [block] for each new block, in order, from the watcher thread
    # @yieldparam block [Hash{Symbol => Object}] normalized block as returned by {#get_block}
    # @yieldreturn [void]
    # @return [Watcher] the started watcher; call {Watcher#stop} to end it
    # @raise [InvalidArgumentError] when a watcher with the same `id` is already running
    def watch_blocks(polling_interval: nil, include_transactions: false, id: nil, &block)
      watch_block_number(polling_interval: polling_interval, emit_missed: true, id: id) do |number|
        block.call(get_block(number, include_transactions: include_transactions))
      end
    end

    # Runs {#get_logs} over a large block range, split in consecutive chunks of at most `max_block_range`
    # blocks so that provider limits are respected.
    #
    # With a block, each chunk's logs are yielded as soon as they are fetched (and the return value is an
    # empty Array); without a block every log is collected and returned at once.
    #
    # @param from_block [Integer] first block of the range (inclusive)
    # @param address [String, #address, Array<String, #address>, nil] address filter, see {#get_logs}
    # @param topics [Array<String, Array<String>, nil>, nil] topic filter, see {#get_logs}
    # @param to_block [Integer, Symbol, String, nil] last block of the range (inclusive). A block tag
    #   (`:latest`, `:earliest`, `:pending`, `:safe`, `:finalized`) or nil is replaced by the current head
    #   (`eth_blockNumber`) before chunking.
    # @param max_block_range [Integer, nil] chunk size in blocks. Defaults to `BlockGiven.config.max_block_range`
    #   (2000).
    # @yield [logs, from, to] once per chunk, in ascending block order
    # @yieldparam logs [Array<Hash{Symbol => Object}>] logs of the chunk (possibly empty), see {#get_logs}
    # @yieldparam from [Integer] first block of the chunk
    # @yieldparam to [Integer] last block of the chunk (inclusive)
    # @yieldreturn [void]
    # @return [Array<Hash{Symbol => Object}>] every log of the range when no block is given, `[]` otherwise
    # @raise [RpcError] when a chunk is rejected by the node
    def get_logs_in_chunks(from_block:, address: nil, topics: nil, to_block: :latest, max_block_range: nil)
      size = max_block_range || BlockGiven.config.max_block_range
      to_block = block_number if to_block.nil? || Utils::BLOCK_TAGS.include?(to_block.to_s)
      collected = []
      from = from_block
      while from <= to_block
        to = [from + size - 1, to_block].min
        logs = get_logs(address: address, topics: topics, from_block: from, to_block: to)
        block_given? ? yield(logs, from, to) : collected.concat(logs)
        from = to + 1
      end
      collected
    end

    # Starts a background {Watcher} yielding new logs matching a filter, one Array per processed block range.
    #
    # On every tick the watcher reads the head (`eth_blockNumber`), subtracts `confirmations`, and walks from
    # the last processed block (excluded) up to that point in ranges of at most `max_block_range` blocks. For
    # each range it calls `eth_getLogs`, yields the logs (only when there are some), calls `on_progress`, then
    # advances {Watcher#cursor} to the range's last block. The cursor is therefore always the last block whose
    # logs were handed to the block: if the block raises, the cursor is not advanced, the error goes through
    # the watcher's error handling and the same range is retried on the next tick.
    #
    # Without `from_block` the watcher starts at the current head (minus `confirmations`) and only reports
    # logs emitted afterwards. With `from_block` it first catches up from that block, chunk by chunk, before
    # following the head; persist the `to` value received by `on_progress` and pass it back as `from_block + 1`
    # to resume after a restart. See the README section "How watchers behave".
    #
    # @example Following Transfer events and persisting a cursor
    #   transfer = BlockGiven::Utils.keccak256("Transfer(address,address,uint256)")
    #   watcher = client.watch_logs(
    #     address: usdc, topics: [transfer], from_block: Cursor.last + 1, confirmations: 2, id: "usdc-transfers",
    #     on_progress: ->(_from, to) { Cursor.save(to) }
    #   ) { |logs| logs.each { |log| Transfers.ingest(log) } }
    #   watcher.cursor # => last processed block number
    #   BlockGiven::Watcher.stop("usdc-transfers", join: 5)
    # @param address [String, #address, Array<String, #address>, nil] address filter, see {#get_logs}
    # @param topics [Array<String, Array<String>, nil>, nil] topic filter, see {#get_logs}
    # @param from_block [Integer, nil] first block to process (inclusive); nil starts at the current head
    # @param polling_interval [Numeric, nil] seconds between two ticks. Defaults to {#polling_interval}.
    # @param max_block_range [Integer, nil] maximum blocks per `eth_getLogs` call. Defaults to
    #   `BlockGiven.config.max_block_range` (2000).
    # @param confirmations [Integer] number of blocks to stay behind the head, to avoid processing logs that a
    #   reorg could remove (0 processes up to the head)
    # @param on_progress [#call, nil] callable invoked with `(from, to)` after each range was yielded and
    #   before the cursor moves; `to` is the last processed block, suited for persistence
    # @param id [String, nil] stable identifier for {Watcher.find} / {Watcher.stop}. Defaults to a generated one.
    # @param name [String, nil] human-readable name shown by {Watcher#inspect}. Defaults to
    #   `"logs@<first address>"` (or `"logs@*"` without address filter).
    # @yield [logs] for each processed range that contains at least one matching log, from the watcher thread
    # @yieldparam logs [Array<Hash{Symbol => Object}>] non-empty normalized logs, see {#get_logs}
    # @yieldreturn [void]
    # @return [Watcher] the started watcher; {Watcher#cursor} holds the last processed block number
    # @raise [InvalidArgumentError] when a watcher with the same `id` is already running
    def watch_logs(address: nil, topics: nil, from_block: nil, polling_interval: nil, max_block_range: nil,
                   confirmations: 0, on_progress: nil, id: nil, name: nil, &block)
      last = from_block ? from_block - 1 : block_number - confirmations
      watcher(name || "logs@#{Array(address).first || '*'}", polling_interval, id: id) do |watcher|
        watcher.cursor ||= last
        head = block_number - confirmations
        while last < head && !watcher.stopped?
          to = [last + (max_block_range || BlockGiven.config.max_block_range), head].min
          logs = get_logs(address: address, topics: topics, from_block: last + 1, to_block: to)
          block.call(logs) unless logs.empty?
          on_progress&.call(last + 1, to)
          last = watcher.cursor = to
        end
      end
    end

    # Builds and starts a generic background {Watcher} bound to this client's polling interval and logger.
    #
    # Every `watch_*` helper goes through this method so that watchers share the registry, the thread naming
    # and the error handling of {Watcher}.
    #
    # @param name [String] human-readable name, also used to generate the id when none is given
    # @param polling_interval [Numeric, nil] seconds between two ticks. Defaults to {#polling_interval}.
    # @param id [String, nil] stable identifier for {Watcher.find} / {Watcher.stop}. Defaults to a generated one.
    # @yield [watcher] on every tick, from the watcher thread
    # @yieldparam watcher [Watcher] the watcher itself (to read {Watcher#stopped?} or set {Watcher#cursor})
    # @yieldreturn [void]
    # @return [Watcher] the started watcher
    # @raise [InvalidArgumentError] when a watcher with the same `id` is already running
    def watcher(name, polling_interval = nil, id: nil, &tick)
      Watcher.new(interval: polling_interval || self.polling_interval, name: name, id: id, logger: logger, &tick).start
    end

    # Short description of the client; the connector's `inspect` never exposes credentials.
    #
    # @return [String]
    def inspect = "#<BlockGiven::Client chain=#{chain} connector=#{connector.inspect}>"

    private

    def block_param(block)
      return block if Utils.hex?(block.to_s) && block.to_s.length == 66

      Utils.block_tag(block)
    end

    def call_object(to:, data:, from:, value:, gas: nil)
      obj = { to: Utils.checksum_address(to) }
      obj[:data] = Utils.prefix_hex(data) if data && data != ""
      obj[:from] = Utils.checksum_address(from) if from
      obj[:value] = Utils.to_hex(value) if value && value != 0
      obj[:gas] = Utils.to_hex(gas) if gas
      obj
    end
  end
end
