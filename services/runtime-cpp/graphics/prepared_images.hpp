#pragma once

#include "frozen_image.hpp"
#include "storage.hpp"

namespace telar::runtime {

template <Allocator Memory>
class PreparedImages {
public:
  explicit PreparedImages(Memory &memory, MediaAllocator<Memory> &budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  void prepare(std::span<const GraphicsImageView> images) noexcept {
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

  std::optional<FrozenImage<Memory>> take(ImageKey key) noexcept {
    for (auto &slot : entries_) {
      if (slot && sameImage(slot->key, key)) {
        auto frozen = std::move(slot->frozen);
        slot.reset();
        return frozen;
      }
    }
    return std::nullopt;
  }

  bool put(ImageKey key, FrozenImage<Memory> &&image) noexcept {
    auto *slot = availableSlot(key.image_id);
    if (slot == nullptr) {
      return false;
    }

    slot->emplace(Entry{key, std::move(image)});
    remember(key);
    return true;
  }

  template <typename Consumer>
  void discardUnwanted(const Consumer &wanted) noexcept {
    for (auto &slot : entries_) {
      if (slot && !wanted(slot->key, true)) {
        slot.reset();
      }
    }
  }

  void clear() noexcept {
    for (auto &slot : entries_) {
      slot.reset();
    }
    frozen_.fill({});
  }

#if TELAR_DIAGNOSTICS
  std::uint64_t takePreparedCount() noexcept {
    return std::exchange(prepared_count_, 0);
  }

  std::size_t storedBytes() const noexcept {
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

  void retain(std::span<const GraphicsImageView> images) noexcept {
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

  bool covered(ImageKey key) const noexcept {
    return std::ranges::any_of(frozen_, [&](auto known) { return known.image_id == key.image_id && known.generation >= key.generation; });
  }

  std::optional<Entry> *availableSlot(std::uint32_t identity) noexcept {
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

  void remember(ImageKey key) noexcept {
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
