#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <cstring>
#include <string_view>

namespace telar::runtime {

class ImportIdentity {
public:
  explicit ImportIdentity(std::string_view source) noexcept {
    constexpr std::uint64_t import_seed = 0x74656c6172696d70;
    const auto low = hash(import_seed, source);
    const auto high = hash(low, source);
    static_assert(std::endian::native == std::endian::little);
    std::memcpy(session.data(), &low, sizeof(low));
    std::memcpy(session.data() + sizeof(low), &high, sizeof(high));
    pane = (low & ((std::uint64_t{1} << 62) - 1)) | 1;
  }

  // These identifiers must match existing imports, including the pinned Wyhash variant.
  static std::uint64_t hash(std::uint64_t seed, std::string_view input) noexcept {
    constexpr std::array<std::uint64_t, 4> secret{0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3};
    std::array<std::uint64_t, 3> state;
    state.fill(seed ^ mix(seed ^ secret[0], secret[1]));
    std::uint64_t left = 0;
    std::uint64_t right = 0;

    if (input.size() <= 16) {
      if (input.size() >= 4) {
        const auto end = input.size() - 4;
        const auto quarter = (input.size() >> 3) << 2;
        left = (read<std::uint32_t>(input.data()) << 32) | read<std::uint32_t>(input.data() + quarter);
        right = (read<std::uint32_t>(input.data() + end) << 32) | read<std::uint32_t>(input.data() + end - quarter);
      } else if (!input.empty()) {
        left = (std::uint64_t{static_cast<unsigned char>(input.front())} << 16) | (std::uint64_t{static_cast<unsigned char>(input[input.size() >> 1])} << 8) | static_cast<unsigned char>(input.back());
      }
    } else {
      std::size_t offset = 0;
      if (input.size() >= 48) {
        while (offset + 48 < input.size()) {
          for (std::size_t lane = 0; lane < state.size(); ++lane) {
            state[lane] = mix(read<std::uint64_t>(input.data() + offset + 16 * lane) ^ secret[lane + 1], read<std::uint64_t>(input.data() + offset + 16 * lane + 8) ^ state[lane]);
          }
          offset += 48;
        }
        state[0] ^= state[1] ^ state[2];
      }

      while (offset + 16 < input.size()) {
        state[0] = mix(read<std::uint64_t>(input.data() + offset) ^ secret[1], read<std::uint64_t>(input.data() + offset + 8) ^ state[0]);
        offset += 16;
      }
      left = read<std::uint64_t>(input.data() + input.size() - 16);
      right = read<std::uint64_t>(input.data() + input.size() - 8);
    }

    const __uint128_t product = static_cast<__uint128_t>(left ^ secret[1]) * (right ^ state[0]);
    return mix(static_cast<std::uint64_t>(product) ^ secret[0] ^ input.size(), static_cast<std::uint64_t>(product >> 64) ^ secret[1]);
  }

  std::array<std::uint8_t, 16> session{};
  std::uint64_t pane = 0;

private:
  template <typename Integer>
  static std::uint64_t read(const char *bytes) noexcept {
    Integer value;
    std::memcpy(&value, bytes, sizeof(value));
    return value;
  }

  static std::uint64_t mix(std::uint64_t left, std::uint64_t right) noexcept {
    const __uint128_t product = static_cast<__uint128_t>(left) * right;
    return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> 64);
  }
};

}
