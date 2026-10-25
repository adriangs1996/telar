#pragma once

#include "telar_client/codecs/telar_wire.hpp"
#include <bit>

namespace telar::runtime::plugins {

class FrameWriter {
public:
  explicit FrameWriter(std::span<Byte> output) noexcept : output_(output), remaining_(output) {}

  template <std::unsigned_integral Integer>
  void integer(Integer value) {
    LittleEndian<Integer>::encode(value, remaining_);
  }

  void timestamp(std::int64_t value) { integer(std::bit_cast<std::uint64_t>(value)); }
  void boolean(bool value) { BoolByte::encode(value, remaining_); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void tag(Enum value) {
    integer(static_cast<Byte>(value));
  }

  void bytes(std::span<const Byte> value) {
    if (value.size() > UINT32_MAX || remaining_.size() < sizeof(std::uint32_t) || value.size() > remaining_.size() - sizeof(std::uint32_t)) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    if (!value.empty()) {
      std::memcpy(remaining_.data(), value.data(), value.size());
    }
    remaining_ = remaining_.subspan(value.size());
  }

  void text(std::string_view value) {
    bytes({reinterpret_cast<const Byte *>(value.data()), value.size()});
  }

  std::span<const Byte> finish() const noexcept { return output_.first(output_.size() - remaining_.size()); }

private:
  std::span<Byte> output_;
  std::span<Byte> remaining_;
};

}
