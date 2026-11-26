export module telar.gui.platform:clipboard_image_pipe;

import std;
import telar.tbc;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
#ifndef __APPLE__
import telar.platform.primitives;
#endif

export {
  namespace telar::gui::platform {

    class ClipboardImageTransfer;

    enum class ClipboardImageError : std::uint8_t {
      no_image,
      changed,
      source_bytes,
      png_bytes,
      pixels,
      invalid_image,
      read_failed,
    };

    class ClipboardImageFailure final : public std::exception {
    public:
      explicit ClipboardImageFailure(ClipboardImageError code) noexcept;

      [[nodiscard]] ClipboardImageError code() const noexcept;
      [[nodiscard]] const char* what() const noexcept override;

    private:
      ClipboardImageError code_;
    };

    // Snapshot on the GUI thread; materialize and encode on one joined worker.
    // The source retains native clipboard ownership without retaining a window.
    class ClipboardImageSource {
    public:
#ifdef __APPLE__
      [[nodiscard]] static ClipboardImageSource retainPasteboard(void* pasteboard);
#endif
      ~ClipboardImageSource();
      ClipboardImageSource(const ClipboardImageSource&) = delete;
      ClipboardImageSource& operator=(const ClipboardImageSource&) = delete;
      ClipboardImageSource(ClipboardImageSource&& other) noexcept;
      ClipboardImageSource& operator=(ClipboardImageSource&& other) noexcept;

      // The capture is allocated from memory.
      [[nodiscard]] tbc::val_a<AttachmentCapture<ApplicationAllocator>> read(tbc::mut_a<ApplicationAllocator> memory, ClipboardCaptureRequest request) const;
      [[nodiscard]] static ClipboardImageSource snapshot(ApplicationAllocator& memory);
#ifndef __APPLE__
      [[nodiscard]] static ClipboardImageSource fromPipe(ApplicationAllocator& memory, runtime::FileDescriptor descriptor, std::shared_ptr<ClipboardImageTransfer> status = {});
#endif

    private:
      explicit ClipboardImageSource(void* native, std::int64_t revision) noexcept;
      void clear() noexcept;

      void* native_ = nullptr;
      std::int64_t revision_ = 0;
    };

    struct ClipboardImagePipeLimits {
      std::size_t source_bytes = AttachmentLimits::maximum_source_bytes;
      std::size_t png_bytes = AttachmentLimits::maximum_png_bytes;
    };

    class ClipboardImagePipe {
    public:
      static constexpr std::chrono::milliseconds timeout{5000};

      template <Allocator Memory>
      [[nodiscard]] static tbc::val_a<SensitiveBytes<Memory>> read(tbc::mut_a<Memory> memory, int descriptor, ClipboardImagePipeLimits limits = {});

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

export namespace telar::gui::platform {
  using telar::gui::eraseSensitiveBytes;
  using telar::gui::SensitiveBytes;
}
