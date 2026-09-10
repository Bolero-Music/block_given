# frozen_string_literal: true

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
  #   watcher = client.watch_block_number { |n| puts n }
  #   sleep 10
  #   watcher.stop
  class Watcher
    attr_reader :interval, :name

    def initialize(interval:, name: "watcher", logger: nil, on_error: nil, &tick)
      raise ::ArgumentError, "a block is required" unless tick

      @interval = interval
      @name = name
      @logger = logger
      @on_error = on_error
      @tick = tick
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @stopped = false
      @thread = nil
    end

    def start
      return self if running?

      @stopped = false
      @thread = Thread.new { run }
      @thread.name = "vium-#{name}"
      @thread.report_on_exception = false
      self
    end

    def stop
      @mutex.synchronize do
        @stopped = true
        @cond.broadcast
      end
      self
    end
    alias unwatch stop

    def running? = !!@thread&.alive?
    def stopped? = @stopped

    def join(timeout = nil)
      @thread&.join(timeout)
      self
    end

    # Replace the error handler. Without a handler errors are logged and polling continues.
    def on_error(&handler)
      @on_error = handler
      self
    end

    private

    def run
      until stopped?
        begin
          @tick.call(self)
        rescue StandardError => e
          handle_error(e)
        end
        wait_interval
      end
    end

    def wait_interval
      @mutex.synchronize { @cond.wait(@mutex, interval) unless @stopped }
    end

    def handle_error(error)
      if @on_error
        @on_error.call(error, self)
      else
        logger.warn { "[vium] #{name}: #{error.class}: #{error.message}" }
      end
    end

    def logger = @logger || Vium.config.logger
  end
end
