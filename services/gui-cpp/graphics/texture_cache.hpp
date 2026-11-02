#pragma once

#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "lifetime.hpp"
#include "store.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>
#include <utility>

namespace telar::gui {

template <typename Resource>
concept TextureResource = std::movable<Resource> && std::is_nothrow_default_constructible_v<Resource> && std::is_nothrow_move_assignable_v<Resource> && requires(const Resource &resource) {
  static_cast<bool>(resource);
};

template <TextureResource Resource, std::size_t Capacity>
class ImageTextureCache {
public:
  struct Entry {
    std::uint32_t image_id = 0;
    std::uint64_t generation = 0;
    Rect bounds;
    Resource resource{};
    std::optional<std::uint64_t> failed_generation = std::nullopt;
    bool needed = false;
    bool resolved_in_frame = false;
  };

  template <Allocator Memory>
  void beginFrame(const GraphicsStore<Memory> &store) noexcept {
    const auto lifetime = store.lifetime();
    if (!lifetime.cacheable() || store_lifetime_ != lifetime) {
      entries_ = {};
      store_lifetime_ = lifetime;
    }

    const auto placements = store.placements();
    for (auto &entry : entries_) {
      entry.resolved_in_frame = false;
      entry.needed = entry.image_id != 0 && std::ranges::any_of(placements, [&](const auto &placement) {
                       return placement.key.image_id == entry.image_id;
                     });
    }
  }

  template <Allocator Memory, typename Upload>
    requires std::same_as<std::invoke_result_t<const Upload &, const typename GraphicsStore<Memory>::Image &>, Resource>
  [[nodiscard]] const Entry *resolve(const GraphicsStore<Memory> &store, ImageKey key, const Upload &upload) {
    auto *entry = find(key.image_id);
    if (entry == nullptr) {
      const auto available = std::ranges::find_if(entries_, [](const auto &candidate) {
        return !candidate.needed;
      });
      if (available == entries_.end()) {
        return nullptr;
      }

      entry = available;
      *entry = {};
      entry->image_id = key.image_id;
      entry->needed = true;
    }

    if (entry->resolved_in_frame) {
      return entry->resource ? entry : nullptr;
    }

    entry->resolved_in_frame = true;
    const auto *image = store.readyImage(key);
    if (image != nullptr) {
      const auto &description = image->description();
      const bool newer = !entry->resource || description.key.generation > entry->generation;
      if (newer && entry->failed_generation != description.key.generation) {
        auto resource = upload(*image);
        if (resource) {
          entry->resource = std::move(resource);
          entry->generation = description.key.generation;
          entry->bounds = {.width = static_cast<float>(description.width), .height = static_cast<float>(description.height)};
          entry->failed_generation.reset();
        } else {
          entry->failed_generation = description.key.generation;
        }
      }
    }

    return entry->resource ? entry : nullptr;
  }

  void endFrame() noexcept {
    for (auto &entry : entries_) {
      if (!entry.needed) {
        entry = {};
      }
    }
  }

private:
  [[nodiscard]] Entry *find(std::uint32_t image_id) noexcept {
    const auto found = std::ranges::find_if(entries_, [image_id](const auto &entry) {
      return entry.image_id == image_id;
    });

    return found == entries_.end() ? nullptr : found;
  }

  std::array<Entry, Capacity> entries_{};
  GraphicsLifetime store_lifetime_;
};

}
