#pragma once

#include "../memory/c_allocation_blocks.hpp"
#include "../memory/erasing_allocator.hpp"
#include <nghttp2/nghttp2.h>
#include <span>
#include <string_view>

namespace telar::runtime {

template <Allocator Memory>
class HpackDecoder {
public:
  static constexpr std::size_t maximum_table_bytes = 128 * 1024;

  explicit HpackDecoder(Memory &memory) noexcept : memory_(memory), blocks_(memory_) {
    callbacks_ = {
        .mem_user_data = &blocks_,
        .malloc = &allocate,
        .free = &release,
        .calloc = &allocateZeroed,
        .realloc = &resize,
    };
    ready_ = nghttp2_hd_inflate_new2(&inflater_, &callbacks_) == 0 && nghttp2_hd_inflate_change_table_size(inflater_, maximum_table_bytes) == 0;
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
  using Blocks = CAllocationBlocks<ErasingAllocator<Memory>>;

  static void *allocate(std::size_t size, void *owner) noexcept {
    return static_cast<Blocks *>(owner)->allocate(size);
  }

  static void release(void *pointer, void *owner) noexcept {
    static_cast<Blocks *>(owner)->release(pointer);
  }

  static void *allocateZeroed(std::size_t count, std::size_t size, void *owner) noexcept {
    return static_cast<Blocks *>(owner)->allocateZeroed(count, size);
  }

  static void *resize(void *pointer, std::size_t size, void *owner) noexcept {
    return static_cast<Blocks *>(owner)->resize(pointer, size);
  }

  ErasingAllocator<Memory> memory_;
  Blocks blocks_;
  // nghttp2 1.70 stores this address in hd_context; the callbacks must outlive the inflater.
  nghttp2_mem callbacks_{};
  nghttp2_hd_inflater *inflater_ = nullptr;
  bool ready_ = false;
};

}
