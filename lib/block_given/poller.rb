# frozen_string_literal: true

require "securerandom"

module BlockGiven
  # Blocking polling helper: calls a block repeatedly until it returns a truthy value or a timeout elapses.
  #
  # Used by {Client#wait_for_transaction_receipt}; background (non-blocking) polling is {Watcher}'s job.
  #
  # @example
  #   receipt = BlockGiven::Poller.poll(interval: 2, timeout: 120, description: "receipt") do
  #     client.get_transaction_receipt(hash)
  #   end
  module Poller
    module_function

    # Calls the block until it returns a non-nil / non-false value, sleeping `interval` seconds between
    # attempts, and returns that value.
    #
    # The timeout is checked after each failed attempt against a monotonic clock, and the last sleep is
    # shortened so the deadline is never overshot by more than one interval. With `timeout: nil` the loop
    # runs until the block succeeds.
    #
    # @param interval [Numeric] seconds slept between two attempts
    # @param timeout [Numeric, nil] seconds after which {TimeoutError} is raised; nil waits forever
    # @param description [String] what is being waited for, used in the {TimeoutError} message
    # @yield [attempt] once per attempt, starting immediately (no initial sleep)
    # @yieldparam attempt [Integer] zero-based attempt counter
    # @yieldreturn [Object, nil, false] the value to return, or nil / false to keep polling
    # @return [Object] the first truthy value returned by the block
    # @raise [TimeoutError] when `timeout` seconds elapsed without the block returning a truthy value
    def poll(interval:, timeout: nil, description: "condition")
      started = monotonic_now
      attempt = 0
      loop do
        result = yield(attempt)
        return result if result

        attempt += 1
        elapsed = monotonic_now - started
        raise TimeoutError, "timed out after #{timeout}s waiting for #{description}" if timeout && elapsed >= timeout

        remaining = timeout ? timeout - elapsed : interval
        sleep([interval, remaining].min)
      end
    end

    # Current reading of the monotonic clock, in seconds (immune to wall-clock adjustments).
    #
    # @api private
    # @return [Float]
    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Background polling loop running in its own thread, returned by the `watch_*` helpers of {Client}.
  #
  # A watcher calls its tick block, sleeps `interval` seconds (interruptible by {#stop}), and repeats until
  # stopped. Exceptions raised by the tick are caught: they are recorded in {#last_error} / {#last_error_at}
  # and either passed to the {#on_error} handler or logged as warnings, and polling continues. The thread is
  # named `block_given:<id>` and does not report exceptions itself.
  #
  # Every running watcher is registered under a unique {#id}, so watchers can be listed ({Watcher.all},
  # {BlockGiven.watchers}) and stopped ({Watcher.stop}, {Watcher.stop_all}) even when the object reference
  # was lost. A watcher leaves the registry when its thread ends (or is killed). Starting a second watcher
  # with the id of a running one raises {InvalidArgumentError}.
  #
  # {#cursor} is free storage for the tick: {Client#watch_logs} keeps the last fully processed block number
  # there, so a supervisor can read where the watcher stands.
  #
  # @example Registry lookups by id
  #   watcher = client.watch_block_number(id: "blocks") { |n| puts n }
  #   BlockGiven.watchers                       # => [#<BlockGiven::Watcher blocks block_number running ...>]
  #   BlockGiven::Watcher.find("blocks").status # => :running
  #   BlockGiven::Watcher.stop("blocks", join: 5)
  #   BlockGiven::Watcher.stop_all
  # @example Custom error handling
  #   watcher.on_error { |error, w| Sentry.capture_exception(error, extra: w.to_h) }
  class Watcher
    @registry = {}
    @registry_mutex = Mutex.new

    class << self
      # Running (or stopping) watchers, oldest first.
      #
      # @return [Array<Watcher>] a snapshot copy of the registry
      def all
        @registry_mutex.synchronize { @registry.values.dup }
      end

      # Looks up a running watcher by id.
      #
      # @example
      #   BlockGiven::Watcher.find("usdc-transfers")&.cursor
      # @param id [String, Symbol, #to_s] watcher id
      # @return [Watcher, nil] the watcher, or nil when no running watcher has this id
      def find(id)
        @registry_mutex.synchronize { @registry[id.to_s] }
      end

      # Looks up a running watcher by id, raising when it is unknown.
      #
      # @param id [String, Symbol, #to_s] watcher id
      # @return [Watcher]
      # @raise [InvalidArgumentError] when no running watcher has this id (the message lists the running ids)
      def find!(id)
        find(id) || raise(InvalidArgumentError, "no running watcher with id #{id.inspect} (running: #{ids.join(', ')})")
      end

      # Ids of the running watchers, oldest first.
      #
      # @return [Array<String>]
      def ids = all.map(&:id)

      # Gracefully stops a watcher by id (see {#stop}) and optionally waits for its thread to end.
      #
      # @example
      #   BlockGiven::Watcher.stop("usdc-transfers", join: 5) # => the watcher, or nil if it was not running
      # @param id [String, Symbol, #to_s] watcher id
      # @param join [Numeric, nil] seconds to wait for the thread after asking it to stop; nil waits until it
      #   ends, but note that {#join} is only called when the watcher exists
      # @return [Watcher, nil] the stopped watcher, or nil when no running watcher has this id
      def stop(id, join: nil)
        watcher = find(id)
        watcher&.stop&.join(join)
      end

      # Forcefully kills a watcher by id (see {#kill}).
      #
      # @param id [String, Symbol, #to_s] watcher id
      # @return [Watcher, nil] the killed watcher, or nil when no running watcher has this id
      def kill(id) = find(id)&.kill

      # Gracefully stops every running watcher, then waits for each thread.
      #
      # @param join [Numeric, nil] seconds to wait for each thread; nil waits until it ends
      # @return [Array<Watcher>] the watchers that were running
      def stop_all(join: nil)
        watchers = all
        watchers.each(&:stop)
        watchers.each { |w| w.join(join) }
        watchers
      end

      # Forcefully kills every running watcher (see {#kill}).
      #
      # @return [Array<Watcher>] the watchers that were running
      def kill_all = all.each(&:kill)

      # Adds a watcher to the registry under its id; called by {#start}.
      #
      # @api private
      # @param watcher [Watcher]
      # @return [Watcher] the registered watcher
      # @raise [InvalidArgumentError] when a different watcher with the same id is already registered
      def register(watcher)
        @registry_mutex.synchronize do
          if (existing = @registry[watcher.id]) && !existing.equal?(watcher)
            raise InvalidArgumentError, "a watcher with id #{watcher.id.inspect} is already running"
          end

          @registry[watcher.id] = watcher
        end
      end

      # Removes a watcher from the registry, only if the registered object is this very watcher.
      #
      # @api private
      # @param watcher [Watcher]
      # @return [Watcher, nil] the removed watcher, or nil when it was not registered
      def unregister(watcher)
        @registry_mutex.synchronize { @registry.delete(watcher.id) if @registry[watcher.id].equal?(watcher) }
      end

      # Builds a unique id from a name: the name with unsafe characters replaced by `_`, plus a random suffix.
      #
      # @example
      #   BlockGiven::Watcher.generate_id("logs@0xAbc") # => "logs@0xAbc-3f9a1c"
      # @param name [String, #to_s] human-readable name
      # @return [String] `"<sanitized name>-<6 hex chars>"`
      def generate_id(name) = "#{name.to_s.gsub(/[^a-zA-Z0-9_.:@-]/, '_')}-#{SecureRandom.hex(3)}"
    end

    # @!attribute [r] id
    #   @return [String] unique identifier used by the registry ({Watcher.find}, {Watcher.stop})
    # @!attribute [r] interval
    #   @return [Numeric] seconds slept between two ticks
    # @!attribute [r] name
    #   @return [String] human-readable name (e.g. `"block_number"`, `"logs@0x..."`)
    # @!attribute [r] started_at
    #   @return [Time, nil] when {#start} was last called; nil while idle
    # @!attribute [r] ticks
    #   @return [Integer] number of completed ticks, including those that raised
    # @!attribute [r] last_error
    #   @return [StandardError, nil] the most recent exception raised by the tick, if any
    # @!attribute [r] last_error_at
    #   @return [Time, nil] when {#last_error} was recorded
    # @!attribute [r] last_tick_at
    #   @return [Time, nil] when the most recent tick finished

    attr_reader :id, :interval, :name, :started_at, :ticks, :last_error, :last_error_at, :last_tick_at
    # Last fully processed position, set by the tick: {Client#watch_logs} stores the last block number whose
    # logs were handed to the caller, and only after they were. nil until the first tick ran.
    #
    # @return [Integer, Object, nil]
    attr_accessor :cursor

    # Builds a watcher without starting it; call {#start}.
    #
    # @param interval [Numeric] seconds slept between two ticks
    # @param name [String, #to_s] human-readable name, also the base of the generated id
    # @param id [String, #to_s, nil] stable identifier for the registry. Defaults to {Watcher.generate_id}.
    # @param logger [Logger, nil] receives a warning per failed tick when no `on_error` handler is set.
    #   Defaults to `BlockGiven.config.logger`.
    # @param on_error [#call, nil] error handler called with `(error, watcher)`; see {#on_error}
    # @yield [watcher] on every tick, from the watcher thread
    # @yieldparam watcher [Watcher] the watcher itself, to check {#stopped?} or update {#cursor}
    # @yieldreturn [void]
    # @raise [ArgumentError] when no block is given
    def initialize(interval:, name: "watcher", id: nil, logger: nil, on_error: nil, &tick)
      raise ::ArgumentError, "a block is required" unless tick

      @interval = interval
      @name = name.to_s
      @id = (id || self.class.generate_id(@name)).to_s
      @logger = logger
      @on_error = on_error
      @tick = tick
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @stopped = false
      @thread = nil
      @ticks = 0
      @started_at = nil
      @last_tick_at = nil
      @last_error = nil
      @last_error_at = nil
    end

    # Registers the watcher and starts its thread (named `block_given:<id>`). No-op when already running.
    #
    # The first tick runs immediately in the new thread. A watcher can be restarted after it stopped.
    #
    # @return [self]
    # @raise [InvalidArgumentError] when another watcher with the same id is running
    def start
      return self if running?

      self.class.register(self)
      @stopped = false
      @started_at = Time.now
      @thread = Thread.new { run }
      @thread.name = "block_given:#{id}"
      @thread.report_on_exception = false
      self
    end

    # Asks the watcher to stop gracefully: the current tick finishes, the sleep is interrupted, then the
    # thread exits and the watcher leaves the registry. Returns at once; use {#join} to wait.
    #
    # @return [self]
    def stop
      @mutex.synchronize do
        @stopped = true
        @cond.broadcast
      end
      self
    end
    alias unwatch stop

    # Stops forcefully: kills the thread even in the middle of a tick and unregisters the watcher at once.
    # Use it when {#stop} does not return because a tick hangs.
    #
    # @return [self]
    def kill
      stop
      @thread&.kill
      self.class.unregister(self)
      self
    end

    # Whether the watcher thread is alive (also true while it is stopping).
    #
    # @return [Boolean]
    def running? = !!@thread&.alive?

    # Whether {#stop} (or {#kill}) was requested; the tick can check it to exit long loops early.
    #
    # @return [Boolean]
    def stopped? = @stopped

    # Lifecycle state of the watcher.
    #
    # @return [Symbol] `:idle` (never started), `:running`, `:stopping` (stop requested, thread still alive)
    #   or `:stopped`
    def status
      return :idle if @thread.nil?
      return :running if running? && !stopped?
      return :stopping if running?

      :stopped
    end

    # Waits for the watcher thread to end.
    #
    # @param timeout [Numeric, nil] seconds to wait; nil waits until the thread ends
    # @return [self] whether or not the thread ended within `timeout`
    def join(timeout = nil)
      @thread&.join(timeout)
      self
    end

    # Replaces the error handler called when a tick raises.
    #
    # Without a handler, errors are logged as warnings and polling continues; with one, the handler decides
    # (it may call {#stop}). Either way the error is recorded in {#last_error} first.
    #
    # @yield [error, watcher] for each exception raised by the tick, from the watcher thread
    # @yieldparam error [StandardError] the exception
    # @yieldparam watcher [Watcher] the watcher itself
    # @yieldreturn [void]
    # @return [self]
    def on_error(&handler)
      @on_error = handler
      self
    end

    # Seconds elapsed since {#start}.
    #
    # @return [Numeric] 0 when the watcher was never started
    def uptime = started_at ? Time.now - started_at : 0

    # Snapshot of the watcher state, suited for health endpoints and logs.
    #
    # @return [Hash{Symbol => Object}] `:id`, `:name`, `:status`, `:interval`, `:cursor`, `:ticks`,
    #   `:started_at`, `:last_tick_at`, `:last_error` (as `"Class: message"` or nil), `:last_error_at` and
    #   `:thread` (the thread name, or nil while idle)
    def to_h
      {
        id: id, name: name, status: status, interval: interval, cursor: cursor, ticks: ticks,
        started_at: started_at, last_tick_at: last_tick_at,
        last_error: last_error && "#{last_error.class}: #{last_error.message}", last_error_at: last_error_at,
        thread: @thread&.name
      }
    end

    # One-line description: id, name, status, cursor, tick count and the class of the last error if any.
    #
    # @return [String]
    def inspect
      error = last_error ? " last_error=#{last_error.class}" : ""
      "#<BlockGiven::Watcher #{id} #{name} #{status} cursor=#{cursor.inspect} ticks=#{ticks}#{error}>"
    end

    private

    def run
      until stopped?
        begin
          @tick.call(self)
        rescue StandardError => e
          handle_error(e)
        ensure
          @ticks += 1
          @last_tick_at = Time.now
        end
        wait_interval
      end
    ensure
      self.class.unregister(self)
    end

    def wait_interval
      @mutex.synchronize { @cond.wait(@mutex, interval) unless @stopped }
    end

    def handle_error(error)
      @last_error = error
      @last_error_at = Time.now
      if @on_error
        @on_error.call(error, self)
      else
        logger.warn { "[block_given] watcher #{id}: #{error.class}: #{error.message}" }
      end
    end

    def logger = @logger || BlockGiven.config.logger
  end
end
