#pragma once

#include "../memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

template <Allocator Memory>
class PendingClipboard {
public:
  static constexpr std::size_t capacity = 1024 * 1024;

  explicit PendingClipboard(Memory &memory) : bytes_(AllocatorRef<Byte, Memory>{memory}) {}

  void replace(std::uint64_t pane, std::span<const Byte> bytes) {
    if (bytes.size() > capacity) {
      throw EncodingError{"Selection exceeds the clipboard limit"};
    }

    Vector<Byte, Memory> replacement{bytes.begin(), bytes.end(), bytes_.get_allocator()};
    bytes_.swap(replacement);
    pane_ = pane;
    pending_ = true;
  }

  bool pending() const noexcept { return pending_; }
  PaneClipboard message() const noexcept { return {.pane_id = pane_, .bytes = bytes_}; }
  void delivered() noexcept { pending_ = false; }

private:
  Vector<Byte, Memory> bytes_;
  std::uint64_t pane_ = 0;
  bool pending_ = false;
};

}
