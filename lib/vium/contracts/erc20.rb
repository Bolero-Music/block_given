# frozen_string_literal: true

module Vium
  # Ready-to-use ERC20 contract (OpenZeppelin v5 ABI, incl. custom errors).
  #
  #   usdc = Vium::ERC20.at("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", wallet: wallet)
  #   usdc.balance_of(wallet.address)
  #   usdc.transfer(to: "0x...", amount: usdc.parse_amount("12.5"))
  class ERC20 < Contract
    abi_file File.expand_path("../../../abis/erc20.json", __dir__)

    def decimals = @decimals ||= read(:decimals)

    # "12.5" -> 12_500_000 (using the token decimals)
    def parse_amount(value) = Utils.parse_units(value, decimals)

    # 12_500_000 -> "12.5"
    def format_amount(value) = Utils.format_units(value, decimals)
  end
end
