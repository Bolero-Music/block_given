# frozen_string_literal: true

# A contract class generated from a Hardhat artifact, with overrides and simulation.
require "bundler/setup"
require "block_given"

BlockGiven.configure do |c|
  c.connector = BlockGiven::Connectors::Alchemy.new(api_key: ENV.fetch("ALCHEMY_API_KEY"))
  c.chain = :base
end

class CatalogMarket < BlockGiven::Contract
  abi_file File.expand_path("../artifacts/CatalogMarket.json", __dir__) # Hardhat artifact ({ "abi": [...] })
  address "0x0000000000000000000000000000000000000001"
end

wallet = BlockGiven::Wallet.new(private_key: ENV.fetch("PRIVATE_KEY"))
market = CatalogMarket.new(wallet: wallet)

# Reads: view/pure functions are eth_call and return decoded Ruby values
listing = market.get_listing(42)                       # tuples come back as Hash: { seller: "0x..", price: 1_000_000 }
price   = market.price_of(42, tx: { block: 20_000_000 }) # historical read

# Dry-run before paying gas: raises BlockGiven::ContractRevertError with the decoded custom error on failure
begin
  market.simulate(:buy, 42, tx: { value: listing[:price] })
rescue BlockGiven::ContractRevertError => e
  abort "would revert: #{e.error_name} #{e.args}"
end

tx = market.buy(42, tx: { value: listing[:price], gas: 250_000 })
puts tx.wait!.inspect
