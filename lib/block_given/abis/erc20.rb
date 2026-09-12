# frozen_string_literal: true

module BlockGiven
  module Abis
    # EIP-20 with the optional metadata functions and the ERC-6093 errors. Inputs use the `to` / `amount`
    # names of OpenZeppelin 4 (OpenZeppelin 5 renamed `amount` to `value`).
    ERC20 = Definition.deep_freeze(
      [
        Definition.view("name", [], ["string"]),
        Definition.view("symbol", [], ["string"]),
        Definition.view("decimals", [], ["uint8"]),
        Definition.view("totalSupply", [], ["uint256"]),
        Definition.view("balanceOf", ["address account"], ["uint256"]),
        Definition.view("allowance", ["address owner", "address spender"], ["uint256"]),
        Definition.write("approve", ["address spender", "uint256 amount"], ["bool"]),
        Definition.write("transfer", ["address to", "uint256 amount"], ["bool"]),
        Definition.write("transferFrom", ["address from", "address to", "uint256 amount"], ["bool"]),

        Definition.event("Transfer", ["address from indexed", "address to indexed", "uint256 value"]),
        Definition.event("Approval", ["address owner indexed", "address spender indexed", "uint256 value"]),

        Definition.error("ERC20InsufficientBalance", ["address sender", "uint256 balance", "uint256 needed"]),
        Definition.error("ERC20InvalidSender", ["address sender"]),
        Definition.error("ERC20InvalidReceiver", ["address receiver"]),
        Definition.error("ERC20InsufficientAllowance", ["address spender", "uint256 allowance", "uint256 needed"]),
        Definition.error("ERC20InvalidApprover", ["address approver"]),
        Definition.error("ERC20InvalidSpender", ["address spender"])
      ]
    )
  end
end
