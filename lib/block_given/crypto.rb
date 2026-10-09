# frozen_string_literal: true

require_relative "crypto/keccak"
require_relative "crypto/secp256k1"

module BlockGiven
  # Cryptographic primitives Ethereum needs, in pure Ruby on top of the OpenSSL standard library: Keccak-256
  # ({Keccak}) and ECDSA over secp256k1 ({Secp256k1}). No native extension is involved beyond OpenSSL.
  #
  # @api private
  module Crypto
    module_function

    # The address controlled by a public key: the last 20 bytes of the keccak-256 of its X and Y coordinates.
    #
    # @param public_key [String] the 65-byte uncompressed public key, binary (`0x04` prefix included)
    # @return [String] the EIP-55 checksummed address
    def address(public_key)
      Utils.checksum_address(Utils.bin_to_hex(Keccak.digest(public_key.byteslice(1, 64)).byteslice(12, 20)))
    end
  end
end
