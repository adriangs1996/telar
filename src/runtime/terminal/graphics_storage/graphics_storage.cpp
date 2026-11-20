module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.terminal.graphics_storage;

import telar.ghostty.vt;
import telar.base.ds;

namespace telar::runtime {

  GraphicsScreenScope::GraphicsScreenScope(GhosttyTerminal terminal)
      : terminal_(terminal),
        original_(GHOSTTY_TERMINAL_SCREEN_PRIMARY) {
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &original_));
  }

  GraphicsScreenScope::~GraphicsScreenScope() {
    ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &original_);
  }

  bool GraphicsScreenScope::select(GhosttyTerminalScreen screen) {
    const auto result = ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &screen);
    if (result == GHOSTTY_NO_VALUE) {
      return false;
    }

    checkGhostty(result);
    return true;
  }

  template <Allocator Memory>
  GraphicsStorageLimits<Memory>::GraphicsStorageLimits(Memory& memory)
      : allocator_(memory) {}

  template <Allocator Memory>
  void GraphicsStorageLimits<Memory>::enforce(GhosttyTerminal terminal) {
    GraphicsScreenScope screen{terminal};

    for (const auto key : {GHOSTTY_TERMINAL_SCREEN_PRIMARY, GHOSTTY_TERMINAL_SCREEN_ALTERNATE}) {
      if (screen.select(key)) {
        enforceScreen(terminal);
      }
    }
  }

  template <Allocator Memory>
  std::size_t GraphicsStorageLimits<Memory>::takeTrimmedImages() noexcept {
    return std::exchange(trimmed_images_, 0);
  }

  template <Allocator Memory>
  std::size_t GraphicsStorageLimits<Memory>::takeTrimmedPlacements() noexcept {
    return std::exchange(trimmed_placements_, 0);
  }

  template <Allocator Memory>
  void GraphicsStorageLimits<Memory>::enforceScreen(GhosttyTerminal terminal) {
    GhosttyKittyGraphics storage = nullptr;

    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, static_cast<void*>(&storage)));
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

  template <Allocator Memory>
  ds::Option<std::uint32_t> GraphicsStorageLimits<Memory>::oldestImage(GhosttyKittyGraphics storage, bool placed) {
    if (images_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_image_iterator_new(allocator_.get(), images_.output()));
    }

    auto* iterator = images_.get();

    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_IMAGE_ITERATOR, static_cast<void*>(&iterator)));
    ds::Option<std::uint32_t> oldest;
    std::uint64_t oldest_generation = std::numeric_limits<std::uint64_t>::max();

    while (const auto* const image = ghostty_kitty_graphics_image_next(iterator)) {
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

  template <Allocator Memory>
  GhosttyKittyGraphicsPlacementIterator GraphicsStorageLimits<Memory>::placements(GhosttyKittyGraphics storage) {
    if (placements_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_placement_iterator_new(allocator_.get(), placements_.output()));
    }

    auto* iterator = placements_.get();

    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, static_cast<void*>(&iterator)));
    return iterator;
  }

  template <Allocator Memory>
  bool GraphicsStorageLimits<Memory>::visible(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
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
    const auto* const image = ghostty_kitty_graphics_image(storage, identity);
    auto rectangle = ghosttySized<GhosttySelection>();

    return image != nullptr && ghostty_kitty_graphics_placement_rect(iterator, image, terminal, &rectangle) == GHOSTTY_SUCCESS &&
           ghostty_terminal_point_from_grid_ref(terminal, &rectangle.end, GHOSTTY_POINT_TAG_ACTIVE, nullptr) == GHOSTTY_SUCCESS;
  }

  bool sameImage(ImageKey left, ImageKey right) noexcept {
    return left.image_id == right.image_id && left.generation == right.generation;
  }

  bool samePlacement(const GraphicsPlacement& left, const GraphicsPlacement& right) noexcept {
    return sameImage(left.key, right.key) && left.virtual_id == right.virtual_id && left.placement_id == right.placement_id &&
           left.x == right.x && left.y == right.y && left.source_x == right.source_x && left.source_y == right.source_y &&
           left.source_width == right.source_width && left.source_height == right.source_height && left.columns == right.columns &&
           left.rows == right.rows && left.offset_x == right.offset_x && left.offset_y == right.offset_y && left.z_index == right.z_index && left.location == right.location;
  }

  template <Allocator Memory>
  GraphicsStorage<Memory>::GraphicsStorage(Memory& memory)
      : allocator_(memory),
        limits_(memory) {}

  template <Allocator Memory>
  void GraphicsStorage<Memory>::update(GhosttyTerminal terminal) {
    limits_.enforce(terminal);
    GhosttyKittyGraphics storage = nullptr;

    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, static_cast<void*>(&storage)));
    std::uint64_t generation = 0;

    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation));
    if (generation == 0 && image_count_ == 0 && placement_count_ == 0) {
      return;
    }

    ds::Array<std::uint32_t, graphics_image_count> identities{};
    std::size_t count = 0;

    checkGhostty(ghostty_kitty_graphics_image_ids(storage, identities.dataMut(), identities.size(), &count));
    count = std::min(count, identities.size());

    bool changed = false;
    std::size_t supported_count = 0;

    for (std::size_t index = 0; index < count; ++index) {
      const auto image = readImage(allocator_.memory(), ghostty_kitty_graphics_image(storage, identities[index]));
      if (image) {
        changed |= !sameImage(images_[supported_count].description.key, image->description.key);
        images_.atMut(supported_count++) = *image;
      }
    }

    changed |= supported_count != image_count_;
    image_count_ = supported_count;

    if (iterator_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_placement_iterator_new(allocator_.get(), iterator_.output()));
    }

    auto* iterator = iterator_.get();

    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, static_cast<void*>(&iterator)));
    std::size_t placement_count = 0;

    while (placement_count < placements_.size() && ghostty_kitty_graphics_placement_next(iterator)) {
      const auto placement = readPlacement(iterator, storage, terminal);
      if (placement) {
        changed |= !samePlacement(placements_[placement_count], *placement);
        placements_.atMut(placement_count++) = *placement;
      }
    }

    changed |= placement_count_ != placement_count;
    placement_count_ = placement_count;
    revision_ += static_cast<std::uint64_t>(changed);
  }

#if TELAR_DIAGNOSTICS
  template <Allocator Memory>
  diagnostics::GraphicsStorageSnapshot GraphicsStorage<Memory>::storageMetrics(GhosttyTerminal terminal) {
    diagnostics::GraphicsStorageSnapshot sample;
    GraphicsScreenScope screen{terminal};

    for (const auto key : {GHOSTTY_TERMINAL_SCREEN_PRIMARY, GHOSTTY_TERMINAL_SCREEN_ALTERNATE}) {
      if (!screen.select(key)) {
        continue;
      }

      GhosttyKittyGraphics storage = nullptr;

      checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, static_cast<void*>(&storage)));
      std::size_t placements = 0;
      std::size_t loading_bytes = 0;

      checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_COUNT, &placements));
      const auto loading = ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_LOADING_BYTES, &loading_bytes);
      if (loading != GHOSTTY_NO_VALUE) {
        checkGhostty(loading);
      }

      sample.placements += placements;
      sample.loading_bytes += loading_bytes;

      ds::Array<std::uint32_t, graphics_image_count> identities{};
      std::size_t count = 0;

      checkGhostty(ghostty_kitty_graphics_image_ids(storage, identities.dataMut(), identities.size(), &count));
      sample.images += count;
      for (const auto identity : std::span{identities}.first(std::min(count, identities.size()))) {
        const auto image = readImage(allocator_.memory(), ghostty_kitty_graphics_image(storage, identity));
        if (image) {
          sample.resident_bytes += image->pixels.size();
        }
      }
    }

    return sample;
  }
#endif

  template <Allocator Memory>
  std::span<const GraphicsImageView> GraphicsStorage<Memory>::images() const noexcept {
    return std::span{images_}.first(image_count_);
  }

  template <Allocator Memory>
  std::span<const GraphicsPlacement> GraphicsStorage<Memory>::placements() const noexcept {
    return std::span{placements_}.first(placement_count_);
  }

  template <Allocator Memory>
  std::uint64_t GraphicsStorage<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  std::size_t GraphicsStorage<Memory>::takeTrimmedImages() noexcept {
    return limits_.takeTrimmedImages();
  }

  template <Allocator Memory>
  std::size_t GraphicsStorage<Memory>::takeTrimmedPlacements() noexcept {
    return limits_.takeTrimmedPlacements();
  }

  template <Allocator Memory>
  tbc::val_a<ds::Option<GraphicsImageView>> GraphicsStorage<Memory>::readImage(tbc::mut_a<Memory> memory, GhosttyKittyGraphicsImage image) {
    GraphicsImageView view{};
    GhosttyKittyImageFormat format{};
    const Byte* pixels = nullptr;
    std::size_t length = 0;
    constexpr ds::Array keys{GHOSTTY_KITTY_IMAGE_DATA_ID, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR};
    ds::Array<void*, keys.size()> values{&view.description.key.image_id, &view.description.key.generation, &view.description.width, &view.description.height, &format, &length, static_cast<void*>(&pixels)};

    checkGhostty(ghostty_kitty_graphics_image_get_multi(image, keys.size(), keys.data(), values.dataMut(), nullptr));
    if (format != GHOSTTY_KITTY_IMAGE_FORMAT_RGB && format != GHOSTTY_KITTY_IMAGE_FORMAT_RGBA) {
      return ds::none;
    }

    view.description.format = format == GHOSTTY_KITTY_IMAGE_FORMAT_RGB ? ImageFormat::rgb : ImageFormat::rgba;
    // Ghostty hands the pixels as a C pointer and length.
#pragma clang unsafe_buffer_usage begin
    view.pixels = {pixels, length};
#pragma clang unsafe_buffer_usage end
    if constexpr (requires(Memory& allocator) { allocator.imagePixels(view.pixels); }) {
      view.pixels = memory.imagePixels(view.pixels);
    }

    view.description.byte_len = view.pixels.size();
    return view;
  }

  template <Allocator Memory>
  ds::Option<GraphicsPlacement> GraphicsStorage<Memory>::readPlacement(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
    GraphicsPlacement placement{};
    bool internal = false;
    bool placeholders = false;
    constexpr ds::Array keys{GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z};
    ds::Array<void*, keys.size()> values{&placement.key.image_id, &placement.placement_id, &internal, &placeholders, &placement.columns, &placement.rows, &placement.offset_x, &placement.offset_y, &placement.z_index};

    checkGhostty(ghostty_kitty_graphics_placement_get_multi(iterator, keys.size(), keys.data(), values.dataMut(), nullptr));
    if (std::ranges::none_of(images(), [&](const auto& image) {
          return image.description.key.image_id == placement.key.image_id;
        })) {
      return ds::none;
    }

    const auto* const image = ghostty_kitty_graphics_image(storage, placement.key.image_id);

    checkGhostty(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &placement.key.generation));
    checkGhostty(ghostty_kitty_graphics_placement_source_rect(iterator, image, &placement.source_x, &placement.source_y, &placement.source_width, &placement.source_height));
    // The virtual id sets the bit above the placement id for the placements a program numbered.
    constexpr unsigned placement_id_bits = 32;

    placement.virtual_id = ((static_cast<std::uint64_t>(!internal) << placement_id_bits) | placement.placement_id) + 1;
    placement.placement_id = internal ? 0 : placement.placement_id;
    if (placeholders) {
      placement.location = PlacementLocation::placeholders;
      placement.offset_x = 0;
      placement.offset_y = 0;
    } else if (ghostty_kitty_graphics_placement_anchor(iterator, terminal, &placement.x, &placement.y) == GHOSTTY_NO_VALUE) {
      return ds::none;
    }

    return placement;
  }

  template class GraphicsStorageLimits<telar::ConcurrentMemory>;
  template class GraphicsStorageLimits<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

  template class GraphicsStorage<telar::ConcurrentMemory>;
  template class GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

}
