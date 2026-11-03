#pragma once

#include "../diagnostics/graphics_storage.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include "storage_limits.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <optional>

namespace telar::runtime {

struct GraphicsImageView {
  ImageDescription description;
  std::span<const Byte> pixels;
};

inline bool sameImage(ImageKey left, ImageKey right) noexcept {
  return left.image_id == right.image_id && left.generation == right.generation;
}

inline bool samePlacement(const GraphicsPlacement &left, const GraphicsPlacement &right) noexcept {
  return sameImage(left.key, right.key) && left.virtual_id == right.virtual_id && left.placement_id == right.placement_id &&
         left.x == right.x && left.y == right.y && left.source_x == right.source_x && left.source_y == right.source_y &&
         left.source_width == right.source_width && left.source_height == right.source_height && left.columns == right.columns &&
         left.rows == right.rows && left.offset_x == right.offset_x && left.offset_y == right.offset_y && left.z_index == right.z_index && left.location == right.location;
}

template <Allocator Memory>
class GraphicsStorage {
public:
  explicit GraphicsStorage(Memory &memory)
      : allocator_(memory),
        limits_(memory) {}

  void update(GhosttyTerminal terminal) {
    limits_.enforce(terminal);
    GhosttyKittyGraphics storage = nullptr;
    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    std::uint64_t generation = 0;
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation));
    if (generation == 0 && image_count_ == 0 && placement_count_ == 0) {
      return;
    }

    std::array<std::uint32_t, graphics_image_count> identities;
    std::size_t count = 0;
    checkGhostty(ghostty_kitty_graphics_image_ids(storage, identities.data(), identities.size(), &count));
    count = std::min(count, identities.size());

    bool changed = false;
    std::size_t supported_count = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const auto image = readImage(ghostty_kitty_graphics_image(storage, identities[index]));
      if (image) {
        changed |= !sameImage(images_[supported_count].description.key, image->description.key);
        images_[supported_count++] = *image;
      }
    }
    changed |= supported_count != image_count_;
    image_count_ = supported_count;

    if (iterator_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_placement_iterator_new(allocator_.get(), iterator_.output()));
    }
    auto iterator = iterator_.get();
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator));
    std::size_t placement_count = 0;
    while (placement_count < placements_.size() && ghostty_kitty_graphics_placement_next(iterator)) {
      const auto placement = readPlacement(iterator, storage, terminal);
      if (placement) {
        changed |= !samePlacement(placements_[placement_count], *placement);
        placements_[placement_count++] = *placement;
      }
    }
    changed |= placement_count_ != placement_count;
    placement_count_ = placement_count;
    revision_ += changed;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::GraphicsStorageSnapshot storageMetrics(GhosttyTerminal terminal) {
    diagnostics::GraphicsStorageSnapshot sample;
    GraphicsScreenScope screen{terminal};
    for (const auto key : {GHOSTTY_TERMINAL_SCREEN_PRIMARY, GHOSTTY_TERMINAL_SCREEN_ALTERNATE}) {
      if (!screen.select(key)) {
        continue;
      }

      GhosttyKittyGraphics storage = nullptr;
      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
      std::size_t placements = 0;
      std::size_t loading_bytes = 0;
      checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_COUNT, &placements));
      const auto loading = ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES, &loading_bytes);
      if (loading != GHOSTTY_NO_VALUE) {
        checkGhostty(loading);
      }
      sample.placements += placements;
      sample.loading_bytes += loading_bytes;

      std::array<std::uint32_t, graphics_image_count> identities;
      std::size_t count = 0;
      checkGhostty(ghostty_kitty_graphics_image_ids(storage, identities.data(), identities.size(), &count));
      sample.images += count;
      for (const auto identity : std::span{identities}.first(std::min(count, identities.size()))) {
        const auto image = readImage(ghostty_kitty_graphics_image(storage, identity));
        if (image) {
          sample.resident_bytes += image->pixels.size();
        }
      }
    }

    return sample;
  }
#endif

  std::span<const GraphicsImageView> images() const noexcept {
    return std::span{images_}.first(image_count_);
  }

  std::span<const GraphicsPlacement> placements() const noexcept {
    return std::span{placements_}.first(placement_count_);
  }

  std::uint64_t revision() const noexcept {
    return revision_;
  }

  std::size_t takeTrimmedImages() noexcept {
    return limits_.takeTrimmedImages();
  }

  std::size_t takeTrimmedPlacements() noexcept {
    return limits_.takeTrimmedPlacements();
  }

private:
  std::optional<GraphicsImageView> readImage(GhosttyKittyGraphicsImage image) {
    GraphicsImageView view{};
    GhosttyKittyImageFormat format{};
    const Byte *pixels = nullptr;
    std::size_t length = 0;
    const GhosttyKittyGraphicsImageData keys[] = {GHOSTTY_KITTY_IMAGE_DATA_ID, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR};
    void *values[] = {&view.description.key.image_id, &view.description.key.generation, &view.description.width, &view.description.height, &format, &length, &pixels};
    checkGhostty(ghostty_kitty_graphics_image_get_multi(image, std::size(keys), keys, values, nullptr));
    if (format != GHOSTTY_KITTY_IMAGE_FORMAT_RGB && format != GHOSTTY_KITTY_IMAGE_FORMAT_RGBA) {
      return std::nullopt;
    }
    view.description.format = format == GHOSTTY_KITTY_IMAGE_FORMAT_RGB ? ImageFormat::rgb : ImageFormat::rgba;
    view.pixels = {pixels, length};
    if constexpr (requires(Memory &memory) { memory.imagePixels(view.pixels); }) {
      view.pixels = allocator_.memory().imagePixels(view.pixels);
    }
    view.description.byte_len = view.pixels.size();
    return view;
  }

  std::optional<GraphicsPlacement> readPlacement(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
    GraphicsPlacement placement{};
    bool internal = false;
    bool placeholders = false;
    const GhosttyKittyGraphicsPlacementData keys[] = {GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z};
    void *values[] = {&placement.key.image_id, &placement.placement_id, &internal, &placeholders, &placement.columns, &placement.rows, &placement.offset_x, &placement.offset_y, &placement.z_index};
    checkGhostty(ghostty_kitty_graphics_placement_get_multi(iterator, std::size(keys), keys, values, nullptr));
    if (std::ranges::none_of(images(), [&](const auto &image) { return image.description.key.image_id == placement.key.image_id; })) {
      return std::nullopt;
    }
    const auto image = ghostty_kitty_graphics_image(storage, placement.key.image_id);
    checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &placement.key.generation));
    checkGhostty(ghostty_kitty_graphics_placement_source_rect(iterator, image, &placement.source_x, &placement.source_y, &placement.source_width, &placement.source_height));
    placement.virtual_id = ((static_cast<std::uint64_t>(!internal) << 32) | placement.placement_id) + 1;
    placement.placement_id = internal ? 0 : placement.placement_id;
    if (placeholders) {
      placement.location = PlacementLocation::placeholders;
      placement.offset_x = 0;
      placement.offset_y = 0;
    } else if (ghostty_kitty_graphics_placement_anchor(iterator, terminal, &placement.x, &placement.y) == GHOSTTY_NO_VALUE) {
      return std::nullopt;
    }
    return placement;
  }

  GhosttyAllocatorBridge<Memory> allocator_;
  GraphicsStorageLimits<Memory> limits_;
  GhosttyHandle<GhosttyKittyGraphicsPlacementIterator, ghostty_kitty_graphics_placement_iterator_free> iterator_;
  std::array<GraphicsImageView, graphics_image_count> images_{};
  std::array<GraphicsPlacement, graphics_placement_count> placements_{};
  std::size_t image_count_ = 0;
  std::size_t placement_count_ = 0;
  std::uint64_t revision_ = 0;
};

}
