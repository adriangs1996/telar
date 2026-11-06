module;

#include "media_budget.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <optional>
#include "telar_platform/trace.hpp"
#include <cstring>
#include <span>
#include <string_view>
#include <sys/mman.h>


#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <cstdint>


#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

export module telar.runtime.graphics.prepared_images;

export import telar.platform;


export import telar.runtime.diagnostics.operation;

// Interface: graphics/frozen_image.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class FrozenImage {
public:
  inline explicit FrozenImage(Memory &memory, MediaAllocator<Memory> &budget, std::span<const std::uint8_t> pixels, bool shared)
      : memory_(&memory),
        budget_(&budget) {
    TELAR_TRACE("media.freezeImage");
    if (!budget_->reserve(pixels.size())) {
      throw std::bad_alloc{};
    }
    byte_count_ = pixels.size();
    reserved_bytes_ = pixels.size();

    try {
      if (shared && freezeShared(pixels)) {
        return;
      }

      pixels_ = static_cast<std::uint8_t *>(memory_->allocate(byte_count_, alignof(std::uint8_t)));
      if (pixels_ == nullptr) {
        throw std::bad_alloc{};
      }
      std::memcpy(pixels_, pixels.data(), pixels.size());
    } catch (...) {
      reset();
      throw;
    }
  }

  inline ~FrozenImage() {
    reset();
  }

  FrozenImage(const FrozenImage &) = delete;
  FrozenImage &operator=(const FrozenImage &) = delete;

  inline FrozenImage(FrozenImage &&other) noexcept {
    take(other);
  }

  FrozenImage &operator=(FrozenImage &&other) noexcept {
    if (this != &other) {
      reset();
      take(other);
    }
    return *this;
  }

  inline std::span<const std::uint8_t> pixels() const noexcept {
    return {pixels_, pixels_ == nullptr ? 0 : byte_count_};
  }

  inline std::size_t byteCount() const noexcept {
    return byte_count_;
  }

  inline std::string_view name() const noexcept {
    return name_.data();
  }

  inline void published() noexcept {
    owns_name_ = false;
  }

  inline static FrozenImage adoptSharedName(SharedImageStorage::Name name, std::size_t byte_count) noexcept {
    FrozenImage image;
    image.name_ = name;
    image.owns_name_ = true;
    image.byte_count_ = byte_count;
    return image;
  }

private:
  FrozenImage() noexcept = default;

  inline bool freezeShared(std::span<const std::uint8_t> pixels) noexcept {
    auto shared = SharedImageStorage::create(pixels.size());
    if (!shared) {
      return false;
    }

    std::memcpy(shared->mapping().bytes().data(), pixels.data(), pixels.size());
    name_ = shared->takeName();
    owns_name_ = true;
    return true;
  }

  inline void removeName() noexcept {
    if (owns_name_) {
      ::shm_unlink(name_.data());
    }
    name_[0] = '\0';
    owns_name_ = false;
  }

  inline void reset() noexcept {
    removeName();
    if (pixels_ != nullptr) {
      memory_->deallocate(pixels_, byte_count_, alignof(std::uint8_t));
      pixels_ = nullptr;
    }
    if (reserved_bytes_ != 0) {
      budget_->release(std::exchange(reserved_bytes_, 0));
    }
    byte_count_ = 0;
  }

  inline void take(FrozenImage &other) noexcept {
    memory_ = other.memory_;
    budget_ = other.budget_;
    pixels_ = std::exchange(other.pixels_, nullptr);
    byte_count_ = std::exchange(other.byte_count_, 0);
    reserved_bytes_ = std::exchange(other.reserved_bytes_, 0);
    name_ = other.name_;
    other.name_[0] = '\0';
    owns_name_ = std::exchange(other.owns_name_, false);
  }

  Memory *memory_ = nullptr;
  MediaAllocator<Memory> *budget_ = nullptr;
  std::uint8_t *pixels_ = nullptr;
  std::size_t byte_count_ = 0;
  std::size_t reserved_bytes_ = 0;
  std::array<char, 32> name_{};
  bool owns_name_ = false;
};

}
}

// Interface: graphics/storage_limits.cppm
export {
namespace telar::runtime {

inline constexpr std::size_t graphics_screen_bytes = 128 * 1024 * 1024;
inline constexpr std::size_t graphics_credit_bytes = 2 * graphics_screen_bytes;
inline constexpr std::size_t graphics_image_count = 32;
inline constexpr std::size_t graphics_placement_count = 128;

class GraphicsScreenScope {
public:
  inline explicit GraphicsScreenScope(GhosttyTerminal terminal)
      : terminal_(terminal) {
    checkGhostty(ghostty_terminal_get(terminal_, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &original_));
  }

  inline ~GraphicsScreenScope() {
    ghostty_terminal_set(terminal_, GHOSTTY_TERMINAL_OPT_ACTIVE_SCREEN, &original_);
  }

  GraphicsScreenScope(const GraphicsScreenScope &) = delete;
  GraphicsScreenScope &operator=(const GraphicsScreenScope &) = delete;

  inline bool select(GhosttyTerminalScreen screen) {
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
  inline explicit GraphicsStorageLimits(Memory &memory)
      : allocator_(memory) {}

  inline void enforce(GhosttyTerminal terminal) {
    GraphicsScreenScope screen{terminal};
    for (const auto key : {GHOSTTY_TERMINAL_SCREEN_PRIMARY, GHOSTTY_TERMINAL_SCREEN_ALTERNATE}) {
      if (screen.select(key)) {
        enforceScreen(terminal);
      }
    }
  }

  inline std::size_t takeTrimmedImages() noexcept {
    return std::exchange(trimmed_images_, 0);
  }

  inline std::size_t takeTrimmedPlacements() noexcept {
    return std::exchange(trimmed_placements_, 0);
  }

private:
  inline void enforceScreen(GhosttyTerminal terminal) {
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

  inline std::optional<std::uint32_t> oldestImage(GhosttyKittyGraphics storage, bool placed) {
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

  inline GhosttyKittyGraphicsPlacementIterator placements(GhosttyKittyGraphics storage) {
    if (placements_.get() == nullptr) {
      checkGhostty(ghostty_kitty_graphics_placement_iterator_new(allocator_.get(), placements_.output()));
    }

    auto iterator = placements_.get();
    checkGhostty(ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator));
    return iterator;
  }

  inline static bool visible(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
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
}

// Interface: graphics/storage.cppm
export {
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
  inline explicit GraphicsStorage(Memory &memory)
      : allocator_(memory),
        limits_(memory) {}

  inline void update(GhosttyTerminal terminal) {
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
  inline diagnostics::GraphicsStorageSnapshot storageMetrics(GhosttyTerminal terminal) {
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

  inline std::span<const GraphicsImageView> images() const noexcept {
    return std::span{images_}.first(image_count_);
  }

  inline std::span<const GraphicsPlacement> placements() const noexcept {
    return std::span{placements_}.first(placement_count_);
  }

  inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  inline std::size_t takeTrimmedImages() noexcept {
    return limits_.takeTrimmedImages();
  }

  inline std::size_t takeTrimmedPlacements() noexcept {
    return limits_.takeTrimmedPlacements();
  }

private:
  inline std::optional<GraphicsImageView> readImage(GhosttyKittyGraphicsImage image) {
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

  inline std::optional<GraphicsPlacement> readPlacement(GhosttyKittyGraphicsPlacementIterator iterator, GhosttyKittyGraphics storage, GhosttyTerminal terminal) {
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
}

// Interface: graphics/prepared_images.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PreparedImages {
public:
  inline explicit PreparedImages(Memory &memory, MediaAllocator<Memory> &budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  inline void prepare(std::span<const GraphicsImageView> images) noexcept {
    TELAR_TRACE("media.prepareShared");
    retain(images);
    for (const auto &image : images) {
      if (covered(image.description.key)) {
        continue;
      }

      auto *slot = availableSlot(image.description.key.image_id);
      if (slot == nullptr) {
        continue;
      }
      slot->reset();
      try {
        FrozenImage<Memory> frozen{memory_, budget_, image.pixels, true};
        if (frozen.name().empty()) {
          continue;
        }
        slot->emplace(Entry{image.description.key, std::move(frozen)});
        remember(image.description.key);
        TELAR_DIAGNOSTIC(diagnostics::accumulate(prepared_count_));
      } catch (...) {
      }
    }
  }

  inline std::optional<FrozenImage<Memory>> take(ImageKey key) noexcept {
    for (auto &slot : entries_) {
      if (slot && sameImage(slot->key, key)) {
        auto frozen = std::move(slot->frozen);
        slot.reset();
        return frozen;
      }
    }
    return std::nullopt;
  }

  inline bool put(ImageKey key, FrozenImage<Memory> &&image) noexcept {
    auto *slot = availableSlot(key.image_id);
    if (slot == nullptr) {
      return false;
    }

    slot->emplace(Entry{key, std::move(image)});
    remember(key);
    return true;
  }

  template <typename Consumer>
  inline void discardUnwanted(const Consumer &wanted) noexcept {
    for (auto &slot : entries_) {
      if (slot && !wanted(slot->key, true)) {
        slot.reset();
      }
    }
  }

  inline void clear() noexcept {
    for (auto &slot : entries_) {
      slot.reset();
    }
    frozen_.fill({});
  }

#if TELAR_DIAGNOSTICS
  inline std::uint64_t takePreparedCount() noexcept {
    return std::exchange(prepared_count_, 0);
  }

  inline std::size_t storedBytes() const noexcept {
    std::size_t bytes = 0;
    for (const auto &entry : entries_) {
      if (entry) {
        bytes += entry->frozen.byteCount();
      }
    }
    return bytes;
  }
#endif

private:
  struct Entry {
    ImageKey key;
    FrozenImage<Memory> frozen;
  };

  inline void retain(std::span<const GraphicsImageView> images) noexcept {
    for (auto &slot : entries_) {
      if (slot && std::ranges::none_of(images, [&](const auto &image) { return sameImage(slot->key, image.description.key); })) {
        slot.reset();
      }
    }
    for (auto &key : frozen_) {
      if (key.image_id != 0 && std::ranges::none_of(images, [&](const auto &image) { return key.image_id == image.description.key.image_id; })) {
        key = {};
      }
    }
  }

  inline bool covered(ImageKey key) const noexcept {
    return std::ranges::any_of(frozen_, [&](auto known) { return known.image_id == key.image_id && known.generation >= key.generation; });
  }

  inline std::optional<Entry> *availableSlot(std::uint32_t identity) noexcept {
    std::optional<Entry> *free = nullptr;
    for (auto &slot : entries_) {
      if (slot && slot->key.image_id == identity) {
        return &slot;
      }
      if (!slot && free == nullptr) {
        free = &slot;
      }
    }
    return free;
  }

  inline void remember(ImageKey key) noexcept {
    auto found = std::ranges::find_if(frozen_, [&](auto known) { return known.image_id == key.image_id; });
    if (found == frozen_.end()) {
      found = std::ranges::find_if(frozen_, [](auto known) { return known.image_id == 0; });
    }
    if (found != frozen_.end()) {
      *found = key;
    }
  }

  static constexpr std::size_t prepared_capacity = 4;
  Memory &memory_;
  MediaAllocator<Memory> &budget_;
  std::array<std::optional<Entry>, prepared_capacity> entries_;
  std::array<ImageKey, graphics_image_count * 2> frozen_{};
#if TELAR_DIAGNOSTICS
  std::uint64_t prepared_count_ = 0;
#endif
};

}
}

// Interface: graphics/transfer_requests.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class TransferRequests {
public:
  inline explicit TransferRequests(Memory &memory, MediaAllocator<Memory> &budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  inline bool request(ImageKey key, bool shared) noexcept {
    std::optional<Entry> *free = nullptr;
    for (auto &entry : entries_) {
      if (entry && entry->shared == shared && sameImage(entry->key, key)) {
        return false;
      }
      if (!entry && free == nullptr) {
        free = &entry;
      }
    }
    if (free == nullptr) {
      return false;
    }
    free->emplace(Entry{.key = key, .shared = shared});
    return true;
  }

  inline std::optional<FrozenImage<Memory>> take(ImageKey key, bool shared) {
    for (auto &entry : entries_) {
      if (!entry || entry->shared != shared || !sameImage(entry->key, key) || entry->state == State::pending) {
        continue;
      }

      const bool failed = entry->state == State::failed;
      auto frozen = std::move(entry->frozen);
      entry.reset();
      if (failed) {
        throw std::bad_alloc{};
      }
      return frozen;
    }
    return std::nullopt;
  }

  inline void process(std::span<const GraphicsImageView> images) noexcept {
    TELAR_TRACE("media.prepareTransfers");
    for (auto &entry : entries_) {
      if (!entry) {
        continue;
      }

      const auto image = std::ranges::find_if(images, [&](const auto &image) { return sameImage(entry->key, image.description.key); });
      if (image == images.end()) {
        entry.reset();
        continue;
      }
      if (entry->state != State::pending) {
        continue;
      }

      try {
        entry->frozen.emplace(memory_, budget_, image->pixels, entry->shared);
        entry->state = State::ready;
      } catch (...) {
        entry->state = State::failed;
      }
    }
  }

  template <typename Consumer>
  inline void discardUnwanted(const Consumer &wanted) noexcept {
    for (auto &entry : entries_) {
      if (entry && !wanted(entry->key, entry->shared)) {
        entry.reset();
      }
    }
  }

  inline void clear() noexcept {
    for (auto &entry : entries_) {
      entry.reset();
    }
  }

#if TELAR_DIAGNOSTICS
  inline std::size_t storedBytes() const noexcept {
    std::size_t bytes = 0;
    for (const auto &entry : entries_) {
      if (entry) {
        bytes += entry->frozen ? entry->frozen->byteCount() : 0;
      }
    }
    return bytes;
  }
#endif

private:
  enum class State {
    pending,
    ready,
    failed
  };

  struct Entry {
    ImageKey key;
    bool shared;
    State state = State::pending;
    std::optional<FrozenImage<Memory>> frozen{};
  };

  Memory &memory_;
  MediaAllocator<Memory> &budget_;
  std::array<std::optional<Entry>, 8> entries_;
};

}
}
