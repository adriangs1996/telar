#pragma once

#include "telar_client/codecs/telar_wire.hpp"
#include <bit>

namespace telar::runtime::plugins {

class FrameReader {
public:
  explicit FrameReader(std::span<const Byte> input) noexcept : remaining_(input) {}

  template <std::unsigned_integral Integer>
  Integer integer() {
    return LittleEndian<Integer>::decode(remaining_);
  }

  std::int64_t timestamp() { return std::bit_cast<std::int64_t>(integer<std::uint64_t>()); }
  bool boolean() { return BoolByte::decode(remaining_); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  Enum tag(Enum maximum) {
    const auto value = integer<Byte>();
    if (value > static_cast<Byte>(maximum)) {
      throw EncodingError{"Unknown tap enumeration value"};
    }
    return static_cast<Enum>(value);
  }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void require(Enum expected) {
    if (integer<Byte>() != static_cast<Byte>(expected)) {
      throw EncodingError{"Unexpected tap frame tag"};
    }
  }

  std::span<const Byte> bytes() {
    const auto length = integer<std::uint32_t>();
    if (length > remaining_.size()) {
      throw EncodingError{"Truncated tap field"};
    }
    const auto value = remaining_.first(length);
    remaining_ = remaining_.subspan(length);
    return value;
  }

  std::string_view text() {
    const auto value = bytes();
    return {reinterpret_cast<const char *>(value.data()), value.size()};
  }

  void finish() const {
    if (!remaining_.empty()) {
      throw EncodingError{"Trailing tap frame bytes"};
    }
  }

private:
  std::span<const Byte> remaining_;
};

}
