# frozen_string_literal: true

module BlockGiven
  module Abis
    # EIP-721 with ERC-165, the metadata and enumerable extensions and the ERC-6093 / enumerable errors.
    # Mutability follows OpenZeppelin (nonpayable) where EIP-721 says payable. Both `safeTransferFrom`
    # overloads are present: pick one by arity or full signature ("safeTransferFrom(address,address,uint256,bytes)").
    ERC721 = Definition.deep_freeze(
      [
        Definition.view("supportsInterface", ["bytes4 interfaceId"], ["bool"]),
        Definition.view("balanceOf", ["address owner"], ["uint256"]),
        Definition.view("ownerOf", ["uint256 tokenId"], ["address"]),
        Definition.view("name", [], ["string"]),
        Definition.view("symbol", [], ["string"]),
        Definition.view("tokenURI", ["uint256 tokenId"], ["string"]),
        Definition.view("getApproved", ["uint256 tokenId"], ["address"]),
        Definition.view("isApprovedForAll", ["address owner", "address operator"], ["bool"]),
        Definition.view("totalSupply", [], ["uint256"]),
        Definition.view("tokenOfOwnerByIndex", ["address owner", "uint256 index"], ["uint256"]),
        Definition.view("tokenByIndex", ["uint256 index"], ["uint256"]),
        Definition.write("approve", ["address to", "uint256 tokenId"]),
        Definition.write("setApprovalForAll", ["address operator", "bool approved"]),
        Definition.write("transferFrom", ["address from", "address to", "uint256 tokenId"]),
        Definition.write("safeTransferFrom", ["address from", "address to", "uint256 tokenId"]),
        Definition.write("safeTransferFrom", ["address from", "address to", "uint256 tokenId", "bytes data"]),

        Definition.event("Transfer", ["address from indexed", "address to indexed", "uint256 tokenId indexed"]),
        Definition.event("Approval", ["address owner indexed", "address approved indexed", "uint256 tokenId indexed"]),
        Definition.event("ApprovalForAll", ["address owner indexed", "address operator indexed", "bool approved"]),

        Definition.error("ERC721InvalidOwner", ["address owner"]),
        Definition.error("ERC721NonexistentToken", ["uint256 tokenId"]),
        Definition.error("ERC721IncorrectOwner", ["address sender", "uint256 tokenId", "address owner"]),
        Definition.error("ERC721InvalidSender", ["address sender"]),
        Definition.error("ERC721InvalidReceiver", ["address receiver"]),
        Definition.error("ERC721InsufficientApproval", ["address operator", "uint256 tokenId"]),
        Definition.error("ERC721InvalidApprover", ["address approver"]),
        Definition.error("ERC721InvalidOperator", ["address operator"]),
        Definition.error("ERC721OutOfBoundsIndex", ["address owner", "uint256 index"]),
        Definition.error("ERC721EnumerableForbiddenBatchMint", [])
      ]
    )
  end
end
