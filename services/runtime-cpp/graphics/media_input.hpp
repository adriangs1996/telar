#pragma once

#include "atomic_frame_filter.hpp"
#include "atomic_frame_loader.hpp"
#include <atomic>

namespace telar::runtime {

template <Allocator Memory>
class MediaInput {
public:
  explicit MediaInput(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared, const std::atomic<unsigned> &shared_clients) noexcept
      : terminal_(terminal),
        atomic_frames_(memory, terminal, prepared),
        shared_clients_(shared_clients) {}

  AtomicFrameFilter::Statistics feed(std::span<const Byte> bytes, std::span<Byte> scratch) {
    const auto remaining = GraphicsFileInput::stripQueries(bytes, scratch, terminal_.storageLimit(), terminal_);
    GraphicsFrameSource source;
    return AtomicFrameFilter::feed(remaining, terminal_.storageLimit(), source, *this);
  }

  void output(std::span<const Byte> bytes) {
    terminal_.feed(bytes);
  }

  bool atomicFrame(const AtomicFrameView &frame) {
    return atomic_frames_.load(frame, shared_clients_.load(std::memory_order_acquire) != 0);
  }

private:
  MediaTerminal<MediaAllocator<Memory>> &terminal_;
  AtomicFrameLoader<Memory> atomic_frames_;
  const std::atomic<unsigned> &shared_clients_;
};

}
