# frozen_string_literal: true

require "openssl"
require "securerandom"

module BlockGiven
  module Crypto
    # ECDSA over secp256k1, the curve Ethereum accounts use: key generation, public key derivation,
    # deterministic signing (RFC 6979, low-s as required by EIP-2, with the recovery id) and public key recovery.
    #
    # Elliptic curve point multiplications go through the OpenSSL standard library (`OpenSSL::PKey::EC::Point`);
    # scalars stay plain Ruby Integers. Signatures are byte-identical to libsecp256k1's and viem's for the same
    # key and hash, since the nonce is derived deterministically from both.
    #
    # @api private
    module Secp256k1
      # Order of the curve's base point.
      N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
      # Field prime.
      P = (2**256) - (2**32) - 977
      # Largest `s` value of a canonical (low-s) signature.
      HALF_N = N >> 1

      module_function

      # The OpenSSL group for the curve, built once.
      #
      # @return [OpenSSL::PKey::EC::Group]
      # @raise [BlockGiven::ConfigurationError] when the linked OpenSSL was built without secp256k1
      def group
        @group ||= OpenSSL::PKey::EC::Group.new("secp256k1")
      rescue OpenSSL::PKey::EC::Group::Error => e
        raise ConfigurationError, "the OpenSSL library Ruby is linked against does not support secp256k1 (#{e.message})"
      end

      # Whether an Integer is a valid private key, i.e. in [1, N - 1].
      #
      # @param key [Integer]
      # @return [Boolean]
      def valid_private_key?(key) = key.is_a?(Integer) && key.positive? && key < N

      # Draws a uniformly random private key from `SecureRandom`.
      #
      # @return [Integer] a key in [1, N - 1]
      def generate_private_key
        loop do
          key = bytes_to_int(SecureRandom.random_bytes(32))
          return key if valid_private_key?(key)
        end
      end

      # The uncompressed public key of a private key.
      #
      # @param private_key [Integer] a key in [1, N - 1]
      # @return [String] 65 binary bytes: `0x04`, then X and Y on 32 bytes each
      def public_key(private_key)
        group.generator.mul(OpenSSL::BN.new(private_key)).to_octet_string(:uncompressed)
      end

      # Signs a 32-byte hash with a nonce derived per RFC 6979 (HMAC-SHA256), normalized to low-s.
      #
      # @param hash [String] the 32-byte message hash, binary
      # @param private_key [Integer] a key in [1, N - 1]
      # @return [Array(Integer, Integer, Integer)] `[r, s, recovery_id]`, `recovery_id` in 0..3 (bit 0: parity of
      #   the nonce point's Y, bit 1: its X overflowed N)
      def sign(hash, private_key)
        z = bytes_to_int(hash) % N
        nonces(int_to_bytes(private_key), int_to_bytes(z)).each do |k|
          point = group.generator.mul(OpenSSL::BN.new(k)).to_octet_string(:uncompressed)
          x = bytes_to_int(point.byteslice(1, 32))
          r = x % N
          next if r.zero?

          s = (blinded_inverse(k) * (z + (r * private_key))) % N
          next if s.zero?

          recovery_id = (point.getbyte(64) & 1) | (x >= N ? 2 : 0)
          return s > HALF_N ? [r, N - s, recovery_id ^ 1] : [r, s, recovery_id]
        end
      end

      # Recovers the uncompressed public key that produced a signature over a hash.
      #
      # @param hash [String] the 32-byte message hash, binary
      # @param r [Integer]
      # @param s [Integer]
      # @param recovery_id [Integer] 0..3
      # @return [String] the 65-byte uncompressed public key, binary
      # @raise [BlockGiven::InvalidArgumentError] when the signature is malformed or matches no curve point
      def recover(hash, r, s, recovery_id)
        unless r.positive? && r < N && s.positive? && s < N && (0..3).cover?(recovery_id)
          raise InvalidArgumentError, "invalid signature"
        end

        x = r + ((recovery_id >> 1) * N)
        raise InvalidArgumentError, "invalid signature" if x >= P

        point_r = decompress(x, recovery_id & 1)
        r_inverse = r.pow(N - 2, N)
        u1 = (-bytes_to_int(hash) * r_inverse) % N
        u2 = (s * r_inverse) % N
        public_key = point_r.mul(OpenSSL::BN.new(u2), OpenSSL::BN.new(u1))
        raise InvalidArgumentError, "invalid signature" if public_key.infinity?

        public_key.to_octet_string(:uncompressed)
      end

      # Candidate nonces of RFC 6979 section 3.2 with HMAC-SHA256, in order (libsecp256k1's nonce function
      # without extra entropy).
      #
      # @param key [String] the private key on 32 bytes
      # @param message [String] the hash reduced modulo N, on 32 bytes
      # @return [Enumerator<Integer>] endless sequence of nonces in [1, N - 1]
      def nonces(key, message)
        Enumerator.new do |yielder|
          v = "\x01".b * 32
          k = "\x00".b * 32
          k = hmac(k, "#{v}\x00".b + key + message)
          v = hmac(k, v)
          k = hmac(k, "#{v}\x01".b + key + message)
          v = hmac(k, v)
          loop do
            v = hmac(k, v)
            candidate = bytes_to_int(v)
            yielder << candidate if valid_private_key?(candidate)
            k = hmac(k, "#{v}\x00".b)
            v = hmac(k, v)
          end
        end
      end

      # The modular inverse of a nonce, computed on a randomly blinded value so that its timing does not depend
      # on the nonce itself.
      #
      # @param k [Integer] a nonce in [1, N - 1]
      # @return [Integer] k^-1 mod N
      def blinded_inverse(k)
        blind = (bytes_to_int(SecureRandom.random_bytes(32)) % (N - 1)) + 1
        ((k * blind) % N).pow(N - 2, N) * blind % N
      end

      # The curve point with a given X coordinate and Y parity.
      #
      # @param x [Integer] X coordinate, below P
      # @param y_parity [Integer] 0 for an even Y, 1 for an odd Y
      # @return [OpenSSL::PKey::EC::Point]
      # @raise [BlockGiven::InvalidArgumentError] when X is not on the curve
      def decompress(x, y_parity)
        OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new((2 + y_parity).chr + int_to_bytes(x), 2))
      rescue OpenSSL::PKey::EC::Point::Error
        raise InvalidArgumentError, "invalid signature"
      end

      # @param key [String] HMAC key
      # @param data [String]
      # @return [String] the 32-byte HMAC-SHA256, binary
      def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)

      # @param bytes [String] big-endian binary
      # @return [Integer]
      def bytes_to_int(bytes) = bytes.unpack1("H*").to_i(16)

      # @param int [Integer] a non-negative Integer below 2**256
      # @return [String] 32 big-endian bytes, binary
      def int_to_bytes(int) = [int.to_s(16).rjust(64, "0")].pack("H*")
    end
  end
end
