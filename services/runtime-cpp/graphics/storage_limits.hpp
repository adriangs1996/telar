#pragma once

#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <cstdint>
#include <optional>

namespace telar::runtime {

inline constexpr std::size_t graphics_screen_bytes = 128 * 1024 * 1024;
inline constexpr std::size_t graphics_credit_bytes = 2 * graphics_screen_bytes;
inline constexpr std::size_t graphics_image_count = 32;
inline constexpr std::size_t graphics_placement_count = 128;

class GraphicsScreenScope {
public:
  explicit GraphicsScreenScope(GhosttyTerminal terminal)
      : terminal_(terminal) {
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &original_));
  }

  ~GraphicsScreenScope() {
    ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &original_);
  }

  GraphicsScreenScope(const GraphicsScreenScope &) = delete;
  GraphicsScreenScope &operator=(const GraphicsScreenScope &) = delete;

  bool select(GhosttyTerminalScreen screen) {
    const auto result = ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &screen);
    if (result == GHOSTTY_NO_VALUE) {
      return false;
    }

    checkGhostty(result);
    return true;
  }

private:
  GhosttyTerminal terminal_;
  GhosttyTerminalScreen original_;
};

template <Allocator Memory>
class GraphicsStorageLimits {
public:
  explicit GraphicsStorageLimits(Memory &memory)
      : allocator_(memory) {}

  void enforce(GhosttyTerminal terminal) {
    GraphicsScreenScope screen{terminal};
    for (const auto key : {GHOSTTY_TERMINAL_SCREEN_PRIMARY, GHOSTTY_TERMINAL_SCREEN_ALTERNATE}) {
      if (screen.select(key)) {
        enforceScreen(terminal);
      }
    }
  }

  std::size_t takeTrimmedImages() noexcept {
    return std::exchange(trimmed_images_, 0);
  }

  std::size_t takeTrimmedPlacements() noexcept {
    return std::exchange(trimmed_placements_, 0);
  }

private:
  void enforceScreen(GhosttyTerminal terminal) {
    GhosttyKittyGraphics storage = nullptr;
    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    std::size_t image_count = 0;
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_IMAGE_COUNT, &image_count));
    if (image_count > graphics_image_count) {
      trimmed_images_ = std::max(trimmed_images_, image_count);
      while (image_count > graphics_image_count) {
        const auto image = oldestImage(storage, false);
        if (!image) {
          break;
        }

        checkGhostty(ghostty_kitty_graphics_image_remove(terminal, *image));
        --image_count;
      }
    }

    std::size_t placement_count = 0;
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_COUNT, &placement_count));
    if (placement_count <= graphics_placement_count) {
      return;
    }

    trimmed_placements_ = std::max(trimmed_placements_, placement_count);
    auto iterator = placements(storage);
    while (placement_count > graphics_placement_count && ghostty_kitty_graphics_placement_next(iterator)) {
      if (!visible(iterator, storage, terminal)) {
        checkGhostty(ghostty_kitty_graphics_placement_remove(iterator, terminal));
        --placement_count;
      }
    }

    while (placement_count > graphics_placement_count) {
      const auto oldest = oldestImage(storage, true);
      if (!oldest) {
        break;
      }

      iterator = placements(storage);
      while (placement_count > graphics_placement_count && ghostty_kitty_graphics_placement_next(iterator)) {
        std::uint32_t image = 0;
        checkGhostty(ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &image));
        if (image == *oldest) {
          checkGhostty(ghostty_kitty_graphics_placement_remove(iterator, terminal));
          --placement_count;
        }
      }
    }
  }

  std::optional<std::uint32_t> oldestImage(GhosttyKittyGraphics storage, bool placed) {
    if (images_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_image_iterator_new(allocator_.get(), images_.output()));
    }

    auto iterator = images_.get();
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_IMAGE_ITERATOR, &iterator));
    std::optional<std::uint32_t> oldest;
    std::uint64_t oldest_generation = UINT64_MAX;
    while (const auto image = ghostty_kitty_graphics_image_next(iterator)) {
      if (placed) {
        std::size_t count = 0;
        checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_PLACEMENT_COUNT, &count));
        if (count == 0) {
          continue;
        }
      }

      std::uint64_t generation = 0;
      checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation));
      if (generation < oldest_generation) {
        std::uint32_t identity = 0;
        checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_ID, &identity));
        oldest = identity;
        oldest_generation = generation;
      }
    }
    return oldest;
  }

  GhosttyKittyGraphicsPlacementIterator placements(GhosttyKittyGraphics storage) {
    if (placements_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_placement_iterator_new(allocator_.get(), placements_.output()));
    }

    auto iterator = placements_.get();
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator));
    return iterator;
  }

  static bool visible(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
    bool placeholders = false;
    checkGhostty(ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &placeholders));
    if (placeholders) {
      return true;
    }

    auto anchor = ghosttySized<GhosttyGridRef>();
    if (ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_GRID_REF, &anchor) == GHOSTTY_NO_VALUE) {
      return false;
    }
    if (ghostty_terminal_point_from_grid_ref(terminal, &anchor, GHOSTTY_POINT_TAG_ACTIVE, nullptr) == GHOSTTY_SUCCESS) {
      return true;
    }

    std::uint32_t identity = 0;
    checkGhostty(ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &identity));
    const auto image = ghostty_kitty_graphics_image(storage, identity);
    auto rectangle = ghosttySized<GhosttySelection>();
    return image != nullptr && ghostty_kitty_graphics_placement_rect(iterator, image, terminal, &rectangle) == GHOSTTY_SUCCESS &&
           ghostty_terminal_point_from_grid_ref(terminal, &rectangle.end, GHOSTTY_POINT_TAG_ACTIVE, nullptr) == GHOSTTY_SUCCESS;
  }

  GhosttyAllocatorBridge<Memory> allocator_;
  GhosttyHandle<GhosttyKittyGraphicsImageIterator, ghostty_kitty_graphics_image_iterator_free> images_;
  GhosttyHandle<GhosttyKittyGraphicsPlacementIterator, ghostty_kitty_graphics_placement_iterator_free> placements_;
  std::size_t trimmed_images_ = 0;
  std::size_t trimmed_placements_ = 0;
};

}
