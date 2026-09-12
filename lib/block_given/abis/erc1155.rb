# frozen_string_literal: true

module BlockGiven
  module Abis
    # EIP-1155 with ERC-165, the metadata URI extension and the ERC-6093 errors (OpenZeppelin 5 naming).
    ERC1155 = Definition.deep_freeze(
      [
        Definition.view("supportsInterface", ["bytes4 interfaceId"], ["bool"]),
        Definition.view("balanceOf", ["address account", "uint256 id"], ["uint256"]),
        Definition.view("balanceOfBatch", ["address[] accounts", "uint256[] ids"], ["uint256[]"]),
        Definition.view("isApprovedForAll", ["address account", "address operator"], ["bool"]),
        Definition.view("uri", ["uint256 id"], ["string"]),
        Definition.write("setApprovalForAll", ["address operator", "bool approved"]),
        Definition.write("safeTransferFrom",
                         ["address from", "address to", "uint256 id", "uint256 value", "bytes data"]),
        Definition.write("safeBatchTransferFrom",
                         ["address from", "address to", "uint256[] ids", "uint256[] values", "bytes data"]),

        Definition.event("TransferSingle",
                         ["address operator indexed", "address from indexed", "address to indexed",
                          "uint256 id", "uint256 value"]),
        Definition.event("TransferBatch",
                         ["address operator indexed", "address from indexed", "address to indexed",
                          "uint256[] ids", "uint256[] values"]),
        Definition.event("ApprovalForAll", ["address account indexed", "address operator indexed", "bool approved"]),
        Definition.event("URI", ["string value", "uint256 id indexed"]),

        Definition.error("ERC1155InsufficientBalance",
                         ["address sender", "uint256 balance", "uint256 needed", "uint256 tokenId"]),
        Definition.error("ERC1155InvalidSender", ["address sender"]),
        Definition.error("ERC1155InvalidReceiver", ["address receiver"]),
        Definition.error("ERC1155MissingApprovalForAll", ["address operator", "address owner"]),
        Definition.error("ERC1155InvalidApprover", ["address approver"]),
        Definition.error("ERC1155InvalidOperator", ["address operator"]),
        Definition.error("ERC1155InvalidArrayLength", ["uint256 idsLength", "uint256 valuesLength"])
      ]
    )
  end
end
