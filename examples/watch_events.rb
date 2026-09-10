# frozen_string_literal: true

# Polls Transfer events on USDC (Base) every 3 seconds until Ctrl-C.
require "bundler/setup"
require "vium"

Vium.configure do |c|
  c.connector = Vium::Connectors::Alchemy.new(api_key: ENV.fetch("ALCHEMY_API_KEY"))
  c.chain = :base
  c.polling_interval = 3
end

usdc = Vium::ERC20.at("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")

blocks = Vium.client.watch_block_number { |n| puts "block #{n}" }

transfers = usdc.watch_event(:Transfer) do |event|
  puts "#{event.transaction_hash[0, 10]} #{event[:from]} -> #{event[:to]}: #{usdc.format_amount(event[:value])} USDC"
end
transfers.on_error { |error, _watcher| warn "polling error: #{error.message}" }

trap("INT") { blocks.stop; transfers.stop }
transfers.join
