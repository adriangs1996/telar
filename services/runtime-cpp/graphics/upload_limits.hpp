#pragma once

#include "../terminal/ghostty_handle.hpp"
#include "kitty_framing.hpp"
#include "limits.hpp"
#include <algorithm>
#include <array>
#include <limits>

namespace telar::runtime {

class GraphicsUploadLimits {
public:
  struct Observation {
    std::optional<std::uint32_t> loading_image;
    std::size_t completed_commands = 0;
  };

  struct Reached {
    bool chunks = false;
    bool bytes = false;
  };

  explicit GraphicsUploadLimits(std::size_t byte_limit, std::size_t chunk_limit = GraphicsLimits::maximum_chunks_per_image) noexcept
      : byte_limit_(byte_limit),
        chunk_limit_(chunk_limit) {}

  Observation observe(GhosttyTerminal terminal, std::span<const std::uint8_t> bytes) {
    Observation observation{.loading_image = loadingImage(storage(terminal))};
    std::size_t position = 0;
    while (const auto transition = framing_.advance(bytes, position)) {
      observation.completed_commands += *transition == KittyFraming::Transition::ended;
    }
    return observation;
  }

  Observation observeEncodedChunk(GhosttyTerminal terminal) {
    // Generated control fields and base64 contain no framing transitions. The opening ESC may still terminate an earlier APC.
    constexpr std::array<std::uint8_t, 5> envelope{0x1b, '_', 'G', 0x1b, '\\'};
    return observe(terminal, envelope);
  }

  std::optional<std::uint32_t> enforce(GhosttyTerminal terminal, const Observation &observation) {
    const auto graphics = storage(terminal);
    const auto loading = loadingImage(graphics);
    if (loading || observation.loading_image) {
      loading_chunks_ += std::min(observation.completed_commands, std::numeric_limits<std::size_t>::max() - loading_chunks_);
    } else {
      loading_chunks_ = 0;
    }

    const bool exceeded_chunks = loading_chunks_ > chunk_limit_;
    if (!loading) {
      loading_chunks_ = 0;
      if (exceeded_chunks && observation.loading_image) {
        checkGhostty(ghostty_kitty_graphics_image_remove(terminal, *observation.loading_image));
        reached_.chunks = true;
        return observation.loading_image;
      }
      return std::nullopt;
    }

    std::size_t bytes = 0;
    checkGhostty(ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES, &bytes));
    if (!exceeded_chunks && bytes <= byte_limit_) {
      return std::nullopt;
    }

    checkGhostty(ghostty_kitty_graphics_loading_abort(terminal));
    loading_chunks_ = 0;
    reached_.chunks |= exceeded_chunks;
    reached_.bytes |= !exceeded_chunks;
    return loading;
  }

  Reached takeReached() noexcept {
    return std::exchange(reached_, {});
  }

private:
  static GhosttyKittyGraphics storage(GhosttyTerminal terminal) {
    GhosttyKittyGraphics graphics = nullptr;
    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics));
    return graphics;
  }

  static std::optional<std::uint32_t> loadingImage(GhosttyKittyGraphics graphics) {
    std::uint32_t identity = 0;
    const auto result = ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_IMAGE_ID, &identity);
    if (result == GHOSTTY_NO_VALUE) {
      return std::nullopt;
    }

    checkGhostty(result);
    return identity;
  }

  KittyFraming framing_;
  std::size_t byte_limit_;
  std::size_t chunk_limit_;
  std::size_t loading_chunks_ = 0;
  Reached reached_;
};

}
