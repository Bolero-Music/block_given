# frozen_string_literal: true

module Vium
  # A decoded event log.
  #
  #   event.name           # => "Transfer"
  #   event.args           # => { from: "0x...", to: "0x...", value: 1000000 }
  #   event[:value]        # => 1000000
  #   event.block_number   # => 12345
  class Event
    attr_reader :name, :signature, :args, :log

    def initialize(name:, signature:, args:, log:)
      @name = name
      @signature = signature
      @args = args
      @log = log
    end

    def [](key) = args[Utils.snake_case(key).to_sym]
    def address = log[:address] && Utils.checksum_address(log[:address])
    def block_number = log[:block_number]
    def block_hash = log[:block_hash]
    def transaction_hash = log[:transaction_hash]
    def transaction_index = log[:transaction_index]
    def log_index = log[:log_index]
    def removed? = !!log[:removed]

    def to_h
      { name: name, args: args, address: address, block_number: block_number,
        transaction_hash: transaction_hash, log_index: log_index }
    end

    def inspect = "#<Vium::Event #{name} #{args.inspect} block=#{block_number}>"
  end
end
