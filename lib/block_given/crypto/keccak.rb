# frozen_string_literal: true

module BlockGiven
  module Crypto
    # Keccak-256 as used by Ethereum: the original Keccak submission (padding byte `0x01`), not the
    # standardized NIST SHA3-256 (padding byte `0x06`), which produces different digests.
    #
    # Pure Ruby implementation of the Keccak-f[1600] permutation with a 1088-bit rate.
    #
    # @api private
    # @example
    #   BlockGiven::Crypto::Keccak.digest("").unpack1("H*")
    #   # => "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    module Keccak # rubocop:disable Metrics/ModuleLength
      # Sponge rate in bytes for a 256-bit output (1600 - 2 * 256 bits).
      RATE = 136
      # Mask keeping lane arithmetic on 64 bits.
      MASK = 0xFFFFFFFFFFFFFFFF
      # Round constants of the iota step, one per round.
      ROUND_CONSTANTS = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
      ].freeze

      module_function

      # Keccak-256 digest of a byte string.
      #
      # @param data [String] the bytes to hash (any encoding, read as binary)
      # @return [String] the 32-byte digest as a binary String
      def digest(data)
        message = data.b
        padding = RATE - (message.bytesize % RATE)
        message << (padding == 1 ? "\x81".b : "\x01".b + ("\x00".b * (padding - 2)) + "\x80".b)

        state = Array.new(25, 0)
        (0...message.bytesize).step(RATE) do |offset|
          message.byteslice(offset, RATE).unpack("Q<17").each_with_index { |lane, i| state[i] ^= lane }
          state = permute(state)
        end
        state.first(4).pack("Q<4")
      end

      # Applies the 24 rounds of Keccak-f[1600] to a state.
      #
      # Unrolled on purpose: lanes live in local variables (about four times faster than indexing an Array in
      # the inner loops). The rho rotation offsets and the pi lane permutation of the specification are baked
      # into the `b*` assignments (lane x + 5y rotated, then moved to y + 5 * ((2x + 3y) % 5)).
      #
      # @param state [Array<Integer>] 25 lanes of 64 bits, indexed by x + 5 * y
      # @return [Array<Integer>] the permuted state, as a new Array
      def permute(state) # rubocop:disable Metrics/MethodLength
        a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
          a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24 = state
        ROUND_CONSTANTS.each do |rc| # rubocop:disable Metrics/BlockLength
          c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20
          c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21
          c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22
          c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23
          c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24
          d0 = c4 ^ (((c1 << 1) | (c1 >> 63)) & MASK)
          d1 = c0 ^ (((c2 << 1) | (c2 >> 63)) & MASK)
          d2 = c1 ^ (((c3 << 1) | (c3 >> 63)) & MASK)
          d3 = c2 ^ (((c4 << 1) | (c4 >> 63)) & MASK)
          d4 = c3 ^ (((c0 << 1) | (c0 >> 63)) & MASK)
          a0 ^= d0
          a1 ^= d1
          a2 ^= d2
          a3 ^= d3
          a4 ^= d4
          a5 ^= d0
          a6 ^= d1
          a7 ^= d2
          a8 ^= d3
          a9 ^= d4
          a10 ^= d0
          a11 ^= d1
          a12 ^= d2
          a13 ^= d3
          a14 ^= d4
          a15 ^= d0
          a16 ^= d1
          a17 ^= d2
          a18 ^= d3
          a19 ^= d4
          a20 ^= d0
          a21 ^= d1
          a22 ^= d2
          a23 ^= d3
          a24 ^= d4
          b0 = a0
          b10 = (((a1 << 1) | (a1 >> 63)) & MASK)
          b20 = (((a2 << 62) | (a2 >> 2)) & MASK)
          b5 = (((a3 << 28) | (a3 >> 36)) & MASK)
          b15 = (((a4 << 27) | (a4 >> 37)) & MASK)
          b16 = (((a5 << 36) | (a5 >> 28)) & MASK)
          b1 = (((a6 << 44) | (a6 >> 20)) & MASK)
          b11 = (((a7 << 6) | (a7 >> 58)) & MASK)
          b21 = (((a8 << 55) | (a8 >> 9)) & MASK)
          b6 = (((a9 << 20) | (a9 >> 44)) & MASK)
          b7 = (((a10 << 3) | (a10 >> 61)) & MASK)
          b17 = (((a11 << 10) | (a11 >> 54)) & MASK)
          b2 = (((a12 << 43) | (a12 >> 21)) & MASK)
          b12 = (((a13 << 25) | (a13 >> 39)) & MASK)
          b22 = (((a14 << 39) | (a14 >> 25)) & MASK)
          b23 = (((a15 << 41) | (a15 >> 23)) & MASK)
          b8 = (((a16 << 45) | (a16 >> 19)) & MASK)
          b18 = (((a17 << 15) | (a17 >> 49)) & MASK)
          b3 = (((a18 << 21) | (a18 >> 43)) & MASK)
          b13 = (((a19 << 8) | (a19 >> 56)) & MASK)
          b14 = (((a20 << 18) | (a20 >> 46)) & MASK)
          b24 = (((a21 << 2) | (a21 >> 62)) & MASK)
          b9 = (((a22 << 61) | (a22 >> 3)) & MASK)
          b19 = (((a23 << 56) | (a23 >> 8)) & MASK)
          b4 = (((a24 << 14) | (a24 >> 50)) & MASK)
          a0 = b0 ^ (~b1 & b2)
          a1 = b1 ^ (~b2 & b3)
          a2 = b2 ^ (~b3 & b4)
          a3 = b3 ^ (~b4 & b0)
          a4 = b4 ^ (~b0 & b1)
          a5 = b5 ^ (~b6 & b7)
          a6 = b6 ^ (~b7 & b8)
          a7 = b7 ^ (~b8 & b9)
          a8 = b8 ^ (~b9 & b5)
          a9 = b9 ^ (~b5 & b6)
          a10 = b10 ^ (~b11 & b12)
          a11 = b11 ^ (~b12 & b13)
          a12 = b12 ^ (~b13 & b14)
          a13 = b13 ^ (~b14 & b10)
          a14 = b14 ^ (~b10 & b11)
          a15 = b15 ^ (~b16 & b17)
          a16 = b16 ^ (~b17 & b18)
          a17 = b17 ^ (~b18 & b19)
          a18 = b18 ^ (~b19 & b15)
          a19 = b19 ^ (~b15 & b16)
          a20 = b20 ^ (~b21 & b22)
          a21 = b21 ^ (~b22 & b23)
          a22 = b22 ^ (~b23 & b24)
          a23 = b23 ^ (~b24 & b20)
          a24 = b24 ^ (~b20 & b21)
          a0 ^= rc
        end
        [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12,
         a13, a14, a15, a16, a17, a18, a19, a20, a21, a22, a23, a24]
      end
    end
  end
end
