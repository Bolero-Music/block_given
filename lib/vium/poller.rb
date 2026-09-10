# frozen_string_literal: true

require "securerandom"

module Vium
  # Blocking polling helper.
  #
  #   receipt = Vium::Poller.poll(interval: 2, timeout: 120) { client.get_transaction_receipt(hash) }
  #
  # The block is called until it returns a non-nil / non-false value, which is
  # returned. Raises Vium::TimeoutError when the timeout elapses.
  module Poller
    module_function

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

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Background polling loop running in its own thread. Returned by the
  # `watch_*` helpers; call #stop (alias #unwatch) to end it.
  #
  # Every running watcher is registered under a unique id, so they can be listed
  # and stopped even when the object reference was lost:
  #
  #   watcher = client.watch_block_number(id: "blocks") { |n| puts n }
  #   Vium.watchers                     # => [#<Vium::Watcher blocks ...>]
  #   Vium::Watcher.find("blocks").stop
  #   Vium::Watcher.stop_all
  class Watcher
    @registry = {}
    @registry_mutex = Mutex.new

    class << self
      # Running (or stopping) watchers, oldest first.
      def all
        @registry_mutex.synchronize { @registry.values.dup }
      end

      def find(id)
        @registry_mutex.synchronize { @registry[id.to_s] }
      end

      def find!(id)
        find(id) || raise(InvalidArgumentError, "no running watcher with id #{id.inspect} (running: #{ids.join(', ')})")
      end

      def ids = all.map(&:id)

      # Graceful stop by id. Returns the watcher, or nil if unknown.
      def stop(id, join: nil)
        watcher = find(id)
        watcher&.stop&.join(join)
      end

      def kill(id) = find(id)&.kill

      def stop_all(join: nil)
        watchers = all
        watchers.each(&:stop)
        watchers.each { |w| w.join(join) }
        watchers
      end

      def kill_all = all.each(&:kill)

      # @api private
      def register(watcher)
        @registry_mutex.synchronize do
          if (existing = @registry[watcher.id]) && !existing.equal?(watcher)
            raise InvalidArgumentError, "a watcher with id #{watcher.id.inspect} is already running"
          end

          @registry[watcher.id] = watcher
        end
      end

      # @api private
      def unregister(watcher)
        @registry_mutex.synchronize { @registry.delete(watcher.id) if @registry[watcher.id].equal?(watcher) }
      end

      def generate_id(name) = "#{name.to_s.gsub(/[^a-zA-Z0-9_.:@-]/, '_')}-#{SecureRandom.hex(3)}"
    end

    attr_reader :id, :interval, :name, :started_at, :ticks, :last_error, :last_error_at, :last_tick_at
    # Last fully processed position (block number for log watchers), set by the tick.
    attr_accessor :cursor

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

    def start
      return self if running?

      self.class.register(self)
      @stopped = false
      @started_at = Time.now
      @thread = Thread.new { run }
      @thread.name = "vium:#{id}"
      @thread.report_on_exception = false
      self
    end

    # Graceful: the current tick finishes, then the thread exits.
    def stop
      @mutex.synchronize do
        @stopped = true
        @cond.broadcast
      end
      self
    end
    alias unwatch stop

    # Forceful: kills the thread even in the middle of a tick (use when stop does not return).
    def kill
      stop
      @thread&.kill
      self.class.unregister(self)
      self
    end

    def running? = !!@thread&.alive?
    def stopped? = @stopped

    def status
      return :idle if @thread.nil?
      return :running if running? && !stopped?
      return :stopping if running?

      :stopped
    end

    def join(timeout = nil)
      @thread&.join(timeout)
      self
    end

    # Replace the error handler. Without a handler errors are logged and polling continues.
    def on_error(&handler)
      @on_error = handler
      self
    end

    def uptime = started_at ? Time.now - started_at : 0

    def to_h
      {
        id: id, name: name, status: status, interval: interval, cursor: cursor, ticks: ticks,
        started_at: started_at, last_tick_at: last_tick_at,
        last_error: last_error && "#{last_error.class}: #{last_error.message}", last_error_at: last_error_at,
        thread: @thread&.name
      }
    end

    def inspect
      error = last_error ? " last_error=#{last_error.class}" : ""
      "#<Vium::Watcher #{id} #{name} #{status} cursor=#{cursor.inspect} ticks=#{ticks}#{error}>"
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
        logger.warn { "[vium] watcher #{id}: #{error.class}: #{error.message}" }
      end
    end

    def logger = @logger || Vium.config.logger
  end
end
