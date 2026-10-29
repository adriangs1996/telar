#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::runtime::base64 {

inline constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

enum class Padding {
  canonical,
  required,
  optional
};

inline constexpr auto encoded_pairs = [] {
  std::array<std::array<char, 2>, alphabet.size() * alphabet.size()> pairs;
  for (std::size_t index = 0; index < pairs.size(); ++index) {
    pairs[index] = {alphabet[index / alphabet.size()], alphabet[index % alphabet.size()]};
  }
  return pairs;
}();

template <Padding Rule = Padding::canonical>
inline std::optional<std::size_t> decode(std::string_view encoded, std::span<std::uint8_t> destination) noexcept {
  const auto remainder = encoded.size() % 4;
  if (remainder != 0 && (Rule != Padding::optional || remainder == 1)) {
    return std::nullopt;
  }

  std::size_t written = 0;
  const auto complete = encoded.size() - remainder;
  for (std::size_t offset = 0; offset < complete; offset += 4) {
    const auto first = alphabet.find(encoded[offset]);
    const auto second = alphabet.find(encoded[offset + 1]);
    const auto third = alphabet.find(encoded[offset + 2]);
    const auto fourth = alphabet.find(encoded[offset + 3]);
    const bool padding = encoded[offset + 3] == '=';
    const bool double_padding = encoded[offset + 2] == '=';
    const auto count = double_padding ? 1 : padding ? 2
                                                    : 3;
    if (first == std::string_view::npos || second == std::string_view::npos ||
        (!double_padding && third == std::string_view::npos) || (!padding && fourth == std::string_view::npos) ||
        (double_padding && (!padding || (Rule == Padding::canonical && (second & 15) != 0))) ||
        (Rule == Padding::canonical && padding && !double_padding && (third & 3) != 0) ||
        (padding && offset + 4 != encoded.size()) || static_cast<std::size_t>(count) > destination.size() - written) {
      return std::nullopt;
    }

    destination[written++] = static_cast<std::uint8_t>((first << 2) | (second >> 4));
    if (count > 1) {
      destination[written++] = static_cast<std::uint8_t>((second << 4) | (third >> 2));
    }
    if (count > 2) {
      destination[written++] = static_cast<std::uint8_t>((third << 6) | fourth);
    }
  }

  if (remainder != 0) {
    const auto first = alphabet.find(encoded[complete]);
    const auto second = alphabet.find(encoded[complete + 1]);
    const auto third = remainder == 3 ? alphabet.find(encoded[complete + 2]) : 0;
    if (first == std::string_view::npos || second == std::string_view::npos || third == std::string_view::npos || remainder - 1 > destination.size() - written) {
      return std::nullopt;
    }
    destination[written++] = static_cast<std::uint8_t>((first << 2) | (second >> 4));
    if (remainder == 3) {
      destination[written++] = static_cast<std::uint8_t>((second << 4) | (third >> 2));
    }
  }
  return written;
}

inline std::optional<std::size_t> encode(std::span<const std::uint8_t> bytes, std::span<char> destination) noexcept {
  const auto complete_groups = bytes.size() / 3;
  const auto remaining = bytes.size() % 3;
  if (complete_groups > destination.size() / 4 || (remaining != 0 && destination.size() - complete_groups * 4 < 4)) {
    return std::nullopt;
  }

  constexpr unsigned pair_bits = 12;
  constexpr auto pair_mask = encoded_pairs.size() - 1;
  std::size_t written = 0;
  std::size_t offset = 0;
  for (std::size_t group = 0; group < complete_groups; ++group) {
    const auto value = (static_cast<std::uint32_t>(bytes[offset]) << 16) | (static_cast<std::uint32_t>(bytes[offset + 1]) << 8) | bytes[offset + 2];
    const auto &first = encoded_pairs[value >> pair_bits];
    const auto &second = encoded_pairs[value & pair_mask];
    std::copy(first.begin(), first.end(), destination.data() + written);
    std::copy(second.begin(), second.end(), destination.data() + written + first.size());
    offset += 3;
    written += 4;
  }

  if (remaining != 0) {
    const auto value = (static_cast<std::uint32_t>(bytes[offset]) << 16) | (remaining == 2 ? static_cast<std::uint32_t>(bytes[offset + 1]) << 8 : 0);
    const auto &first = encoded_pairs[value >> pair_bits];
    std::copy(first.begin(), first.end(), destination.data() + written);
    destination[written + 2] = remaining == 2 ? alphabet[(value >> 6) & (alphabet.size() - 1)] : '=';
    destination[written + 3] = '=';
    written += 4;
  }

  return written;
}

}
