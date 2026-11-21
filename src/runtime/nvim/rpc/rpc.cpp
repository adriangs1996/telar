module telar.runtime.nvim.rpc;

import std;
import telar.base.memory.allocators;

namespace telar::runtime {

  NvimInbox::NvimInbox(ConcurrentMemory& memory)
      : partial_(memory) {}

  bool NvimInbox::keep(std::span<const std::uint8_t> piece) {
    if (piece.size() > message_limit - partial_.size()) {
      return false;
    }

    partial_.extend(piece);
    return true;
  }

  std::size_t NvimInbox::buffered() const noexcept {
    return partial_.size();
  }

}
