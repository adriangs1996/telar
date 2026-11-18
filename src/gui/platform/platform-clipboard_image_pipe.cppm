module;
#include "platform/clipboard_image_source.hpp"

export module telar.gui.platform:clipboard_image_pipe;

import std;
import telar.base.ds;

export {
  namespace telar::gui::platform {

    struct ClipboardImagePipeLimits {
      std::size_t source_bytes = AttachmentLimits::maximum_source_bytes;
      std::size_t png_bytes = AttachmentLimits::maximum_png_bytes;
    };

    class ClipboardImagePipe {
    public:
      static constexpr std::chrono::milliseconds timeout{5000};

      template <Allocator Memory>
      [[nodiscard]] static SensitiveBytes<Memory> read(Memory& memory, int descriptor, ClipboardImagePipeLimits limits = {});

    private:
      static constexpr std::size_t chunk_bytes = std::size_t{16} * 1024;

      struct Chunk {
        ds::Array<std::byte, chunk_bytes> bytes{};

        Chunk() = default;
        Chunk(const Chunk&) = delete;
        Chunk& operator=(const Chunk&) = delete;
        Chunk(Chunk&&) = delete;
        Chunk& operator=(Chunk&&) = delete;

        ~Chunk();
      };

      [[nodiscard]] static std::chrono::milliseconds now();

      static void waitReadable(int descriptor, std::chrono::milliseconds deadline);
    };

    extern template SensitiveBytes<telar::Memory> ClipboardImagePipe::read<telar::Memory>(telar::Memory& memory, int descriptor, ClipboardImagePipeLimits limits);
    extern template SensitiveBytes<telar::ConcurrentMemory> ClipboardImagePipe::read<telar::ConcurrentMemory>(telar::ConcurrentMemory& memory, int descriptor, ClipboardImagePipeLimits limits);

  }
}

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui::platform {
  using platform::ClipboardImageError;
  using platform::ClipboardImageFailure;
  using telar::gui::eraseSensitiveBytes;
  using telar::gui::SensitiveBytes;
}
