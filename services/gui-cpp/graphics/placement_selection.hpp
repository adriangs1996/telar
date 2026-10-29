#pragma once

#include "image_draw_budget.hpp"
#include "lifetime.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <string_view>
#include <tuple>
#include <utility>

namespace telar::gui {

class ImagePlacementSelection {
public:
  static constexpr std::size_t capacity = ImageDrawBudget::capacity;
  static constexpr std::string_view limit_name = "gui.images.placements_per_frame";
  static constexpr std::string_view limit_noun = "image placements";

  enum class Layer : std::uint8_t {
    below_background,
    below_text,
    above_text,
  };

  struct Identity {
    GraphicsLifetime catalog;
    std::uint64_t virtual_id = 0;
    std::uint32_t image_id = 0;

    bool operator==(const Identity &) const noexcept = default;
  };

  struct Candidate {
    Identity identity;
    Layer layer = Layer::above_text;
    std::int32_t z_index = 0;
  };

  void begin() noexcept {
    candidate_count_ = 0;
    dropped_ = 0;
  }

  void keep(Candidate candidate) noexcept {
    if (candidate_count_ < capacity) {
      candidates_[candidate_count_] = candidate;
      siftUp(candidate_count_++);
      return;
    }

    ++dropped_;
    if (paintsBelow(candidates_.front(), candidate)) {
      candidates_.front() = candidate;
      siftDown();
    }
  }

  [[nodiscard]] bool finish() noexcept {
    const auto candidates = std::span{candidates_}.first(candidate_count_);
    std::ranges::sort(candidates, {}, [](const Candidate &candidate) {
      return identityKey(candidate.identity);
    });
    const auto previous = std::span{selected_}.first(selected_count_);
    const bool changed = !std::ranges::equal(candidates, previous, {}, &Candidate::identity);
    if (!changed) {
      return false;
    }

    selected_count_ = candidate_count_;
    image_count_ = candidate_count_;
    for (std::size_t index = 0; index < selected_count_; ++index) {
      selected_[index] = candidates_[index].identity;
      images_[index] = imageKey(selected_[index]);
    }

    const auto images = std::span{images_}.first(image_count_);
    std::ranges::sort(images);
    image_count_ = static_cast<std::size_t>(std::ranges::unique(images).begin() - images.begin());
    ++revision_;

    return true;
  }

  [[nodiscard]] bool contains(GraphicsLifetime catalog, std::uint64_t virtual_id) const noexcept {
    const auto selected = std::span{selected_}.first(selected_count_);
    return std::ranges::binary_search(selected, std::tuple{catalog.value, virtual_id}, {}, [](const Identity &identity) {
      return identityKey(identity);
    });
  }

  [[nodiscard]] bool containsImage(GraphicsLifetime catalog, std::uint32_t image_id) const noexcept {
    return std::ranges::binary_search(std::span{images_}.first(image_count_), ImageIdentity{catalog.value, image_id});
  }

  [[nodiscard]] std::span<const Identity> selected() const noexcept {
    return std::span{selected_}.first(selected_count_);
  }

  [[nodiscard]] std::size_t dropped() const noexcept {
    return dropped_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] static Layer layer(const GraphicsPlacement &placement) noexcept {
    if (placement.location == PlacementLocation::placeholders) {
      return Layer::below_text;
    }

    constexpr auto below_background_limit = std::numeric_limits<std::int32_t>::min() / 2;
    if (placement.z_index < below_background_limit) {
      return Layer::below_background;
    }

    return placement.z_index < 0 ? Layer::below_text : Layer::above_text;
  }

private:
  using ImageIdentity = std::tuple<std::uint64_t, std::uint32_t>;
  static constexpr std::size_t heap_children = 2;

  [[nodiscard]] static std::tuple<std::uint64_t, std::uint64_t> identityKey(const Identity &identity) noexcept {
    return {identity.catalog.value, identity.virtual_id};
  }

  [[nodiscard]] static ImageIdentity imageKey(const Identity &identity) noexcept {
    return {identity.catalog.value, identity.image_id};
  }

  [[nodiscard]] static bool paintsBelow(const Candidate &left, const Candidate &right) noexcept {
    return std::tuple{left.layer, left.z_index} < std::tuple{right.layer, right.z_index};
  }

  void siftUp(std::size_t index) noexcept {
    while (index > 0) {
      const auto parent = (index - 1) / heap_children;
      if (!paintsBelow(candidates_[index], candidates_[parent])) {
        return;
      }

      std::swap(candidates_[index], candidates_[parent]);
      index = parent;
    }
  }

  void siftDown() noexcept {
    std::size_t index = 0;
    while (true) {
      auto lowest = index;
      const auto left = (heap_children * index) + 1;
      const auto right = left + 1;
      if (left < candidate_count_ && paintsBelow(candidates_[left], candidates_[lowest])) {
        lowest = left;
      }

      if (right < candidate_count_ && paintsBelow(candidates_[right], candidates_[lowest])) {
        lowest = right;
      }

      if (lowest == index) {
        return;
      }

      std::swap(candidates_[index], candidates_[lowest]);
      index = lowest;
    }
  }

  std::array<Candidate, capacity> candidates_{};
  std::array<Identity, capacity> selected_{};
  std::array<ImageIdentity, capacity> images_{};
  std::size_t candidate_count_ = 0;
  std::size_t selected_count_ = 0;
  std::size_t image_count_ = 0;
  std::size_t dropped_ = 0;
  std::uint64_t revision_ = 0;
};

}
