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

  AtomicFrameFilter::Statistics feed(std::span<const Byte> bytes) {
    terminal_.requireOpen();
    CheckedSource source{{}, terminal_};
    return AtomicFrameFilter::feed(bytes, terminal_.storageLimit(), source, *this);
  }

  void output(std::span<const Byte> bytes) {
    terminal_.feed(bytes);
  }

  bool atomicFrame(const AtomicFrameView &frame) {
    terminal_.requireOpen();
    return atomic_frames_.load(frame, shared_clients_.load(std::memory_order_acquire) != 0);
  }

private:
  struct CheckedSource {
    GraphicsFrameSource source;
    MediaTerminal<MediaAllocator<Memory>> &terminal;

    bool available(const AtomicFrameResource &resource) {
      terminal.requireOpen();
      return source.available(resource);
    }

    void release(const AtomicFrameResource &resource) {
      terminal.requireOpen();
      source.release(resource);
    }
  };

  MediaTerminal<MediaAllocator<Memory>> &terminal_;
  AtomicFrameLoader<Memory> atomic_frames_;
  const std::atomic<unsigned> &shared_clients_;
};

template <Allocator Memory>
MediaInput(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared, const std::atomic<unsigned> &shared_clients) -> MediaInput<Memory>;

}
