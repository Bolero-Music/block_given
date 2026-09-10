# frozen_string_literal: true

# ALCHEMY_API_KEY=... PRIVATE_KEY=0x... bundle exec ruby examples/erc20_transfer.rb
require "bundler/setup"
require "vium"

Vium.configure do |c|
  c.connector = Vium::Connectors::Alchemy.new(api_key: ENV.fetch("ALCHEMY_API_KEY"))
  c.chain = :base_sepolia
  c.polling_interval = 2
end

wallet = Vium::Wallet.new(private_key: ENV.fetch("PRIVATE_KEY"))
usdc = Vium::ERC20.at("0x036CbD53842c5426634e7929541eC2318f3dCF7e", wallet: wallet) # USDC on Base Sepolia

puts "#{usdc.symbol} balance: #{usdc.format_amount(usdc.balance_of(wallet))}"

tx = usdc.transfer(to: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", amount: usdc.parse_amount("0.01"))
puts "sent #{tx.hash} -> #{tx.explorer_url}"

receipt = tx.wait!
puts "mined in block #{receipt.block_number}, gas used #{receipt.gas_used}"
usdc.events_from(receipt).each { |event| puts "#{event.name}: #{event.args}" }
