#pragma once

#include "frame_pixels.hpp"
#include "image_allocation.hpp"
#include "media_terminal.hpp"
#include "prepared_images.hpp"

namespace telar::runtime {

template <Allocator Memory>
class AtomicFrameLoader {
public:
  explicit AtomicFrameLoader(MediaAllocator<Memory> &memory, MediaTerminal<MediaAllocator<Memory>> &terminal, PreparedImages<Memory> &prepared) noexcept
      : memory_(memory),
        terminal_(terminal),
        prepared_(prepared) {}

  bool load(const AtomicFrameView &frame, bool shared_transport) {
    TELAR_TRACE("media.loadAtomicFrame");
    const auto child = GraphicsFramePixels::open({frame.encoded_name, frame.control.byte_count, terminal_.storageLimit(), frame.control.medium});
    if (!child) {
      return false;
    }

    ImageAllocation allocation{memory_, frame.control.byte_count};
    if (!allocation) {
      return false;
    }

    auto storage = SharedImageStorage::create(frame.control.byte_count);
    if (!storage || !child->copyTo(storage->mapping().bytes()) || !storage->mapping().protect(PROT_READ) || !allocation.adopt(storage->mapping())) {
      return false;
    }

    terminal_.feed(frame.bytes.first(frame.command_start));
    // Ghostty owns a placeholder; the allocator owns and charges the full mapping.
    // Keeping native storage accounting separate matches its eviction behavior.
    if (!terminal_.insertImage(frame.control, allocation.placeholder())) {
      allocation.reset();
      storage.reset();
      terminal_.feed(frame.bytes.subspan(frame.command_end));
      return true;
    }
    allocation.release();

    place(frame.control.key);
    terminal_.feed(frame.bytes.subspan(frame.command_end));
    if (shared_transport) {
      auto frozen = FrozenImage<Memory>::adoptSharedName(storage->takeName(), frame.control.byte_count);
      prepared_.put(terminal_.imageKey(frame.control.key.image_id), std::move(frozen));
    }
    return true;
  }

private:
  void place(AtomicFrameKey key) {
    std::array<char, 64> command;
    auto *end = std::copy_n("\x1b_Ga=p,i=", 9, command.data());
    end = std::to_chars(end, command.data() + command.size(), key.image_id).ptr;
    end = std::copy_n(",p=", 3, end);
    end = std::to_chars(end, command.data() + command.size(), key.placement_id).ptr;
    end = std::copy_n(",C=1,q=2\x1b\\", 10, end);
    terminal_.feed({reinterpret_cast<const Byte *>(command.data()), static_cast<std::size_t>(end - command.data())});
  }

  MediaAllocator<Memory> &memory_;
  MediaTerminal<MediaAllocator<Memory>> &terminal_;
  PreparedImages<Memory> &prepared_;
};

}
