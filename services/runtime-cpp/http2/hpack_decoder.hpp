#pragma once

#include "memory.hpp"
#include <nghttp2/nghttp2.h>
#include <span>
#include <string_view>

namespace telar::runtime {

template <Allocator Memory>
class HpackDecoder {
public:
  static constexpr std::size_t maximum_table_bytes = 128 * 1024;

  explicit HpackDecoder(Memory &memory) noexcept : memory_(memory) {
    ready_ = nghttp2_hd_inflate_new2(&inflater_, memory_.callbacks()) == 0 && nghttp2_hd_inflate_change_table_size(inflater_, maximum_table_bytes) == 0;
  }

  ~HpackDecoder() {
    if (inflater_ != nullptr) {
      nghttp2_hd_inflate_del(inflater_);
    }
  }

  HpackDecoder(const HpackDecoder &) = delete;
  HpackDecoder &operator=(const HpackDecoder &) = delete;

  bool ready() const noexcept {
    return ready_;
  }

  template <typename Visitor>
    requires requires(Visitor visit, std::string_view name, std::string_view value) {
      { visit(name, value) } noexcept -> std::same_as<void>;
    }
  bool decode(std::span<const std::uint8_t> bytes, Visitor visit) noexcept {
    if (!ready_) {
      return false;
    }
    for (;;) {
      nghttp2_nv field;
      int flags = NGHTTP2_HD_INFLATE_NONE;
      const auto consumed = nghttp2_hd_inflate_hd2(inflater_, &field, &flags, bytes.data(), bytes.size(), 1);
      if (consumed < 0 || static_cast<std::size_t>(consumed) > bytes.size()) {
        ready_ = false;
        return false;
      }
      bytes = bytes.subspan(static_cast<std::size_t>(consumed));
      if ((flags & NGHTTP2_HD_INFLATE_EMIT) != 0) {
        visit({reinterpret_cast<const char *>(field.name), field.namelen}, {reinterpret_cast<const char *>(field.value), field.valuelen});
      }
      if ((flags & NGHTTP2_HD_INFLATE_FINAL) != 0) {
        ready_ = nghttp2_hd_inflate_end_headers(inflater_) == 0;
        return ready_;
      }
      if (consumed == 0 && (flags & NGHTTP2_HD_INFLATE_EMIT) == 0) {
        ready_ = false;
        return false;
      }
    }
  }

private:
  // The inflater retains the callback address; memory_ must outlive it.
  Http2Memory<Memory> memory_;
  nghttp2_hd_inflater *inflater_ = nullptr;
  bool ready_ = false;
};

}
