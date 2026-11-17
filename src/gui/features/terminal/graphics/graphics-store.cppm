module;
#include "tbc/annotations.hpp"

// The images a pane holds as the runtime sends them, the bytes every pane's images count
// against, and the limits that stop them.
export module telar.gui.features.terminal.graphics:store;

import std;

import telar.base.memory.allocators;
import telar.config.core;
import telar.gui.foundation.core;
import telar.wire.graphics;
import telar.wire.vocabulary;

// Interface: graphics/lifetime.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    struct GraphicsLifetime {
      std::uint64_t value = 0;

      [[nodiscard]] static GraphicsLifetime next() noexcept;
      [[nodiscard]] bool cacheable() const noexcept;

      bool operator==(const GraphicsLifetime&) const noexcept = default;
    };

  }
}

// Interface: graphics/limit.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    enum class GraphicsLimitKind : std::uint8_t {
      images,
      placements,
      chunks,
      bytes,
    };

    class GraphicsLimitError final : public std::exception {
    public:
      explicit GraphicsLimitError(GraphicsLimitKind kind);

      [[nodiscard]] const char* what() const noexcept override;
      [[nodiscard]] GraphicsLimitKind kind() const noexcept;
      [[nodiscard]] static const char* name(GraphicsLimitKind kind) noexcept;

    private:
      GraphicsLimitKind kind_;
    };

  }
}

// How a pane paused after a limit asks the runtime for its images again: at most
// `requests_per_window` requests in each healthy window, the window doubling up to
// `maximum_doublings` times while the limits keep being reached.
export namespace telar::gui::features::terminal::graphics {

  struct GraphicsPauseLimits {
    static constexpr std::uint64_t healthy_window_ns = 60'000'000'000;
    static constexpr std::uint8_t requests_per_window = 3;
    static constexpr std::uint8_t maximum_doublings = 4;
  };

}

// Interface: graphics/resync_required.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    class GraphicsResyncRequired final : public std::exception {
    public:
      [[nodiscard]] const char* what() const noexcept override;
    };

  }
}

// Interface: graphics/store.cppm
export {
  namespace telar::gui::features::terminal::graphics {

    // The bytes every pane's graphics hold, which each store counts against. It hands out nothing, so a
    // reference to it stays valid whatever any store records.
    struct TBC_SHARED GraphicsBudget {
      static constexpr std::size_t global_capacity = runtime::GraphicsLimits::maximum_global_bytes;
      std::size_t used = 0;
    };

    template <Allocator Memory>
    class GraphicsStore {
    public:
      static constexpr std::size_t image_capacity = 64;
      static constexpr std::size_t placement_capacity = 256;
      static constexpr std::size_t byte_capacity = runtime::GraphicsLimits::maximum_pane_bytes;
      static constexpr std::size_t chunk_capacity = runtime::GraphicsLimits::maximum_chunks_per_image;

      class Image {
      public:
        Image(Memory& memory, ImageDescription description);
        ~Image();

        Image(const Image&) = delete;
        Image& operator=(const Image&) = delete;
        Image(Image&&) = delete;
        Image& operator=(Image&&) = delete;

        void append(std::uint64_t offset, std::span<const Byte> bytes);

        // Generic over the caller's shared image source.
        template <typename Source>
        TBC_GENERIC bool readShared(Source& source) {
          if (received_ != 0 || chunks_ != 0) {
            throw EncodingError{"Shared image already received pixels"};
          }

          if (!source.read(std::span<Byte>{pixels_, static_cast<std::size_t>(description_.byte_len)})) {
            return false;
          }

          received_ = description_.byte_len;
          return true;
        }

        [[nodiscard]] bool ready() const noexcept;
        [[nodiscard]] std::span<const Byte> pixels() const noexcept;
        [[nodiscard]] const ImageDescription& description() const noexcept;
        void retire() noexcept;
        [[nodiscard]] bool retired() const noexcept;

      private:
        ImageDescription description_;
        AllocatorRef<Byte, Memory> allocator_;
        Byte* pixels_ = nullptr;
        std::size_t received_ = 0;
        std::size_t chunks_ = 0;
        bool retired_ = false;
      };

      GraphicsStore(Memory& memory, GraphicsBudget& budget);
      ~GraphicsStore();

      GraphicsStore(const GraphicsStore&) = delete;
      GraphicsStore& operator=(const GraphicsStore&) = delete;
      GraphicsStore(GraphicsStore&&) = delete;
      GraphicsStore& operator=(GraphicsStore&&) = delete;

      bool snapshot(const GraphicsSnapshot& message);
      bool image(const GraphicsImage& message);
      bool chunk(const GraphicsImageChunk& message);

      // Generic over the caller's shared image source.
      template <typename Source>
      TBC_GENERIC bool sharedImage(const GraphicsSharedImage& message, Source& source) {
        if (!accept(message.header.revision)) {
          return false;
        }

        image(GraphicsImage{.header = message.header, .image = message.image});
        auto* received = findImage(message.image.key);
        if (received == nullptr || !received->readShared(source)) {
          requireSnapshot();

          throw GraphicsResyncRequired{};
        }

        retireOtherGenerations(message.image.key);
        ++revision_;
        return true;
      }

      bool placement(const GraphicsPlacementMessage& message);
      bool erase(const GraphicsDeleteImage& message);
      bool erase(const GraphicsDeletePlacement& message);
      [[nodiscard]] Image* findImage(ImageKey key) const noexcept;
      [[nodiscard]] const Image* readyImage(ImageKey key) const noexcept;
      [[nodiscard]] std::span<const GraphicsPlacement> placements() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] GraphicsLifetime lifetime() const noexcept;
      [[nodiscard]] std::size_t globalRetainedBytes() const noexcept;
      std::uint64_t takeCredit() noexcept;
      void detach() noexcept;

    private:
      void retireOtherGenerations(ImageKey current) noexcept;
      void collectRetired(std::uint32_t image_id) noexcept;
      void requireSnapshot() noexcept;
      [[noreturn]] void reached(GraphicsLimitKind kind);
      [[nodiscard]] bool containsImageId(std::uint32_t id) const noexcept;
      [[nodiscard]] std::size_t logicalImageCount() const noexcept;
      [[nodiscard]] bool hasPlacementReference(ImageKey key) const noexcept;
      void validatePlacement(const GraphicsPlacement& placement) const;
      static bool sameKey(ImageKey left, ImageKey right) noexcept;
      bool accept(std::uint64_t revision);
      void eraseImage(std::size_t index) noexcept;
      void clear() noexcept;

      Memory& memory_;
      GraphicsBudget& budget_;
      Vector<Owned<Image, Memory>, Memory> images_;
      Vector<GraphicsPlacement, Memory> placements_;
      std::size_t bytes_ = 0;
      std::uint64_t released_bytes_ = 0;
      std::uint64_t latest_revision_ = 0;
      std::uint64_t revision_ = 0;
      GraphicsLifetime lifetime_ = GraphicsLifetime::next();
      std::optional<std::uint64_t> snapshot_revision_;
      bool awaiting_snapshot_ = false;
    };

    extern template class GraphicsStore<Memory>;
    extern template class GraphicsStore<ConcurrentMemory>;

  }
}
