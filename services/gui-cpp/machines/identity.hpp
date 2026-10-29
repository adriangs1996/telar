#pragma once

#include "failure.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui {

template <typename Random>
concept MachineIdentityRandom = requires(Random &random, std::span<std::uint8_t> bytes) {
  { random.fill(bytes) } -> std::same_as<void>;
};

class MachineId {
public:
  static constexpr std::string_view prefix = "m-";
  static constexpr std::size_t hex_digits = 12;
  static constexpr std::size_t text_bytes = prefix.size() + hex_digits;
  static constexpr unsigned bits_per_digit = 4;
  static constexpr unsigned value_bits = hex_digits * bits_per_digit;
  static constexpr auto maximum_value = (std::uint64_t{1} << value_bits) - 1;

  [[nodiscard]] static MachineId fromRaw(std::uint64_t value) {
    if (value == 0 || value > maximum_value) {
      throw MachineFailure{MachineError::invalid_id};
    }

    MachineId identity;
    identity.value_ = value;

    return identity;
  }

  [[nodiscard]] static MachineId parse(std::string_view text) {
    if (text.size() != text_bytes || !text.starts_with(prefix)) {
      throw MachineFailure{MachineError::invalid_id};
    }

    std::uint64_t value = 0;
    for (const char digit : text.substr(prefix.size())) {
      const auto index = digits.find(digit);
      if (index == std::string_view::npos) {
        throw MachineFailure{MachineError::invalid_id};
      }

      value = (value << bits_per_digit) | index;
    }

    return fromRaw(value);
  }

  template <MachineIdentityRandom Random>
  [[nodiscard]] static MachineId generate(Random &random) {
    constexpr unsigned bits_per_byte = 8;
    constexpr unsigned entropy_bits = sizeof(std::uint64_t) * bits_per_byte;
    for (;;) {
      std::array<std::uint8_t, sizeof(std::uint64_t)> bytes{};
      random.fill(bytes);
      std::uint64_t value = 0;
      for (std::size_t index = 0; index < bytes.size(); ++index) {
        value |= static_cast<std::uint64_t>(bytes[index]) << (index * bits_per_byte);
      }

      value >>= entropy_bits - value_bits;
      if (value != 0) {
        return fromRaw(value);
      }
    }
  }

  [[nodiscard]] BoundedText<text_bytes> format() const {
    BoundedText<text_bytes> text;
    text.append(prefix);
    for (std::size_t position = hex_digits; position != 0; --position) {
      const auto shift = (position - 1) * bits_per_digit;
      text.append(digits.substr((value_ >> shift) & digit_mask, 1));
    }

    return text;
  }

  [[nodiscard]] std::uint64_t value() const noexcept {
    return value_;
  }

  bool operator==(const MachineId &) const = default;

private:
  static constexpr std::string_view digits = "0123456789abcdef";
  static constexpr auto digit_mask = (std::uint64_t{1} << bits_per_digit) - 1;
  std::uint64_t value_ = 0;
};

}
