#pragma once

#include "frame_output.hpp"

namespace telar::runtime::plugins {

class FrameSize {
public:
  template <std::unsigned_integral Integer>
  void integer(Integer) { add(sizeof(Integer)); }

  void timestamp(std::int64_t) { integer(std::uint64_t{}); }
  void boolean(bool) { integer(Byte{}); }

  template <typename Enum>
    requires std::is_enum_v<Enum>
  void tag(Enum) { integer(Byte{}); }

  void bytes(std::span<const Byte> value) {
    if (value.size() > UINT32_MAX) {
      throw EncodingError{"Tap field exceeds its frame buffer"};
    }
    integer(std::uint32_t{});
    add(value.size());
  }

  void text(std::string_view value) {
    bytes({reinterpret_cast<const Byte *>(value.data()), value.size()});
  }

  std::size_t finish() const noexcept { return size_; }

private:
  void add(std::size_t count) { size_ = checkedWireSize(size_, count); }

  std::size_t size_ = 0;
};

static_assert(FrameOutput<FrameSize>);

}
