#pragma once

#include "box_curve.hpp"
#include "box_metrics.hpp"
#include <array>
#include <bit>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <type_traits>
#include <utility>

namespace telar::gui::glyphs {

template <std::movable Payload>
class CurveCache {
public:
  static constexpr std::size_t capacity = 56;
  static constexpr std::uint16_t raster_limit = 256;
  static constexpr std::uint16_t fallback_width = 16;
  static constexpr std::uint16_t fallback_height = 32;

  template <typename Builder>
    requires std::invocable<Builder> && std::same_as<std::invoke_result_t<Builder>, std::optional<Payload>>
  [[nodiscard]] Payload *resolve(const BoxMetrics &metrics, BoxCurve::Shape shape, Builder &&build) {
    const Key key{.width_bits = std::bit_cast<std::uint32_t>(metrics.width), .height_bits = std::bit_cast<std::uint32_t>(metrics.height), .thickness_bits = std::bit_cast<std::uint32_t>(metrics.light), .shape = shape};
    for (auto &entry : std::span{entries_}.first(count_)) {
      if (entry.key == key) {
        return entry.payload ? &*entry.payload : nullptr;
      }
    }

    if (count_ == capacity) {
      return nullptr;
    }

    auto &entry = entries_[count_++];
    entry.key = key;
    entry.payload = std::invoke(std::forward<Builder>(build));

    return entry.payload ? &*entry.payload : nullptr;
  }

  void reset() noexcept {
    for (auto &entry : std::span{entries_}.first(count_)) {
      entry.payload.reset();
    }

    count_ = 0;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

private:
  struct Key {
    std::uint32_t width_bits = 0;
    std::uint32_t height_bits = 0;
    std::uint32_t thickness_bits = 0;
    BoxCurve::Shape shape = BoxCurve::Shape::rounded_down_right;

    bool operator==(const Key &) const = default;
  };

  struct Entry {
    Key key;
    std::optional<Payload> payload;
  };

  std::array<Entry, capacity> entries_{};
  std::size_t count_ = 0;
};

}
