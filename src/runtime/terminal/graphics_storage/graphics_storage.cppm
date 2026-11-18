module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.graphics_storage;

import std;
import telar.ghostty.vt;
import telar.tbc;

import telar.runtime.diagnostics.operation;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.runtime.terminal.control;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;
import telar.base.ds;

// Interface: graphics/storage_limits.cppm
export {
  namespace telar::runtime {

    inline constexpr std::size_t graphics_screen_bytes = 128 * 1024 * 1024;
    inline constexpr std::size_t graphics_credit_bytes = 2 * graphics_screen_bytes;
    inline constexpr std::size_t graphics_image_count = 32;
    inline constexpr std::size_t graphics_placement_count = 128;

    class GraphicsScreenScope {
    public:
      explicit GraphicsScreenScope(GhosttyTerminal terminal);

      ~GraphicsScreenScope();

      GraphicsScreenScope(const GraphicsScreenScope&) = delete;
      GraphicsScreenScope& operator=(const GraphicsScreenScope&) = delete;

      bool select(GhosttyTerminalScreen screen);

    private:
      GhosttyTerminal terminal_;
      GhosttyTerminalScreen original_;
    };

    template <Allocator Memory>
    class GraphicsStorageLimits {
    public:
      explicit GraphicsStorageLimits(Memory& memory);

      void enforce(GhosttyTerminal terminal);

      std::size_t takeTrimmedImages() noexcept;

      std::size_t takeTrimmedPlacements() noexcept;

    private:
      void enforceScreen(GhosttyTerminal terminal);

      ds::Option<std::uint32_t> oldestImage(GhosttyKittyGraphics storage, bool placed);

      GhosttyKittyGraphicsPlacementIterator placements(GhosttyKittyGraphics storage);

      static bool visible(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal);

      GhosttyAllocatorBridge<Memory> allocator_;
      GhosttyHandle<GhosttyKittyGraphicsImageIterator, ghostty_kitty_graphics_image_iterator_free> images_;
      GhosttyHandle<GhosttyKittyGraphicsPlacementIterator, ghostty_kitty_graphics_placement_iterator_free> placements_;
      std::size_t trimmed_images_ = 0;
      std::size_t trimmed_placements_ = 0;
    };

    extern template class GraphicsStorageLimits<telar::ConcurrentMemory>;
    extern template class GraphicsStorageLimits<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

  }
}

// Interface: graphics/storage.cppm
export {
  namespace telar::runtime {

    struct GraphicsImageView {
      ImageDescription description;
      std::span<const Byte> pixels;
    };

    bool sameImage(ImageKey left, ImageKey right) noexcept;

    bool samePlacement(const GraphicsPlacement& left, const GraphicsPlacement& right) noexcept;

    template <Allocator Memory>
    class GraphicsStorage {
    public:
      explicit GraphicsStorage(Memory& memory);

      void update(GhosttyTerminal terminal);

#if TELAR_DIAGNOSTICS
      diagnostics::GraphicsStorageSnapshot storageMetrics(GhosttyTerminal terminal);
#endif

      std::span<const GraphicsImageView> images() const noexcept;

      std::span<const GraphicsPlacement> placements() const noexcept;

      std::uint64_t revision() const noexcept;

      std::size_t takeTrimmedImages() noexcept;

      std::size_t takeTrimmedPlacements() noexcept;

    private:
      // The pixels are the terminal's, which the allocator maps: the view borrows the allocator, region `a`.
      static tbc::view<ds::Option<GraphicsImageView>, tbc::lt::a> readImage(tbc::view<Memory&, tbc::lt::a> memory, GhosttyKittyGraphicsImage image);

      ds::Option<GraphicsPlacement> readPlacement(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal);

      GhosttyAllocatorBridge<Memory> allocator_;
      GraphicsStorageLimits<Memory> limits_;
      GhosttyHandle<GhosttyKittyGraphicsPlacementIterator, ghostty_kitty_graphics_placement_iterator_free> iterator_;
      std::array<GraphicsImageView, graphics_image_count> images_{};
      std::array<GraphicsPlacement, graphics_placement_count> placements_{};
      std::size_t image_count_ = 0;
      std::size_t placement_count_ = 0;
      std::uint64_t revision_ = 0;
    };

    extern template class GraphicsStorage<telar::ConcurrentMemory>;
    extern template class GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

  }
}
