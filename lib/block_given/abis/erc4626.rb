# frozen_string_literal: true

module BlockGiven
  module Abis
    # EIP-4626 tokenized vault: the full ERC20 interface plus the vault functions, events and
    # OpenZeppelin 5 errors.
    ERC4626 = Definition.deep_freeze(
      ERC20 + [
        Definition.view("asset", [], ["address"]),
        Definition.view("totalAssets", [], ["uint256"]),
        Definition.view("convertToShares", ["uint256 assets"], ["uint256"]),
        Definition.view("convertToAssets", ["uint256 shares"], ["uint256"]),
        Definition.view("maxDeposit", ["address receiver"], ["uint256"]),
        Definition.view("previewDeposit", ["uint256 assets"], ["uint256"]),
        Definition.write("deposit", ["uint256 assets", "address receiver"], ["uint256"]),
        Definition.view("maxMint", ["address receiver"], ["uint256"]),
        Definition.view("previewMint", ["uint256 shares"], ["uint256"]),
        Definition.write("mint", ["uint256 shares", "address receiver"], ["uint256"]),
        Definition.view("maxWithdraw", ["address owner"], ["uint256"]),
        Definition.view("previewWithdraw", ["uint256 assets"], ["uint256"]),
        Definition.write("withdraw", ["uint256 assets", "address receiver", "address owner"], ["uint256"]),
        Definition.view("maxRedeem", ["address owner"], ["uint256"]),
        Definition.view("previewRedeem", ["uint256 shares"], ["uint256"]),
        Definition.write("redeem", ["uint256 shares", "address receiver", "address owner"], ["uint256"]),

        Definition.event("Deposit",
                         ["address sender indexed", "address owner indexed", "uint256 assets", "uint256 shares"]),
        Definition.event("Withdraw",
                         ["address sender indexed", "address receiver indexed", "address owner indexed",
                          "uint256 assets", "uint256 shares"]),

        Definition.error("ERC4626ExceededMaxDeposit", ["address receiver", "uint256 assets", "uint256 max"]),
        Definition.error("ERC4626ExceededMaxMint", ["address receiver", "uint256 shares", "uint256 max"]),
        Definition.error("ERC4626ExceededMaxWithdraw", ["address owner", "uint256 assets", "uint256 max"]),
        Definition.error("ERC4626ExceededMaxRedeem", ["address owner", "uint256 shares", "uint256 max"])
      ]
    )
  end
end
