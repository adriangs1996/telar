#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::gui {

struct TabStripGeometry {
  static constexpr std::size_t maximum_tabs = 64;
  static constexpr std::size_t cap_iterations = 24;
  static constexpr float pill_height = 30;
  static constexpr float pill_radius = 10;
  static constexpr float leading = 5;
  static constexpr float trailing = 12;
  static constexpr float spacing = 8;
  static constexpr float chip_side = 20;
  static constexpr float chip_radius = 6;
  static constexpr float chip_alpha = 0.06F;
  static constexpr float selected_chip_alpha = 0.1F;
  static constexpr float mark_side = 14;
  static constexpr float gap = 2;
  static constexpr float inactive_maximum = 220;
  static constexpr float selected_maximum = 300;
  static constexpr float selected_share = 0.55F;
  static constexpr float caption_minimum = 56;
  static constexpr float counter_width = 36;
  static constexpr float fade_width = 20;
  static constexpr float plus_side = 30;

  enum class Fit : std::uint8_t { full, truncated, compact };

  struct Metrics {
    float leading;
    float trailing;
    float spacing;
    float gap;
    float inactive_maximum;
    float selected_maximum;
    float caption_minimum;
    float counter;

    [[nodiscard]] static Metrics scaled(float ratio) noexcept {
      return {
          .leading = TabStripGeometry::leading * ratio,
          .trailing = TabStripGeometry::trailing * ratio,
          .spacing = TabStripGeometry::spacing * ratio,
          .gap = TabStripGeometry::gap * ratio,
          .inactive_maximum = TabStripGeometry::inactive_maximum * ratio,
          .selected_maximum = TabStripGeometry::selected_maximum * ratio,
          .caption_minimum = TabStripGeometry::caption_minimum * ratio,
          .counter = TabStripGeometry::counter_width * ratio,
      };
    }
  };

  struct Measure {
    float caption = 0;
    float chip = 0;
    float status = 0;

    [[nodiscard]] float statusSpace(const Metrics &metrics) const noexcept {
      return status > 0 ? metrics.spacing + status : 0;
    }

    [[nodiscard]] float whole(const Metrics &metrics) const noexcept {
      return metrics.leading + chip + metrics.spacing + caption + statusSpace(metrics) + metrics.trailing;
    }

    [[nodiscard]] float truncated(const Metrics &metrics) const noexcept {
      return std::min(whole(metrics), metrics.leading + chip + metrics.spacing + metrics.caption_minimum + statusSpace(metrics) + metrics.trailing);
    }

    [[nodiscard]] float compact(const Metrics &metrics) const noexcept {
      return (2 * metrics.leading) + chip + statusSpace(metrics);
    }
  };

  struct Room {
    float width;
    Metrics metrics;
  };

  struct Plan {
    std::array<float, maximum_tabs> widths{};
    std::array<Fit, maximum_tabs> fits{};
    std::size_t first = 0;
    std::size_t end = 0;
    std::size_t focus = 0;
    std::size_t count = 0;

    [[nodiscard]] std::size_t hidden() const noexcept {
      return count - (end - first);
    }

    [[nodiscard]] bool shows(std::size_t index) const noexcept {
      return index >= first && index < end;
    }

    [[nodiscard]] std::optional<std::size_t> nearestHidden() const noexcept {
      if (hidden() == 0) {
        return std::nullopt;
      }

      const auto left = first > 0 ? focus - (first - 1) : std::numeric_limits<std::size_t>::max();
      const auto right = end < count ? end - focus : std::numeric_limits<std::size_t>::max();

      return left <= right ? first - 1 : end;
    }

    [[nodiscard]] float footprint(const Metrics &metrics) const noexcept {
      if (first == end) {
        return 0;
      }

      float used = 0;
      for (auto index = first; index < end; ++index) {
        used += widths[index];
      }

      const auto gaps = metrics.gap * static_cast<float>(end - first - 1);
      used += gaps;
      if (hidden() != 0) {
        used += metrics.gap + metrics.counter;
      }

      return used;
    }
  };

  [[nodiscard]] static Plan arrange(std::span<const Measure> sizes, std::size_t focus, const Room &room) noexcept {
    if (sizes.empty() || sizes.size() > maximum_tabs || focus >= sizes.size() || !std::isfinite(room.width) || room.width < 0) {
      return {};
    }

    const auto &metrics = room.metrics;
    Plan result{.first = 0, .end = sizes.size(), .focus = focus, .count = sizes.size()};
    const auto whole = sizes[focus].whole(metrics);
    const auto width = std::max(sizes[focus].compact(metrics), std::min({whole, metrics.selected_maximum, room.width * selected_share}));
    result.widths[focus] = width;
    result.fits[focus] = width >= whole ? Fit::full : Fit::truncated;
    const auto gaps = metrics.gap * static_cast<float>(sizes.size() - 1);
    const auto after_focus = room.width - width;
    const auto budget = after_focus - gaps;
    float natural = 0;
    float shortest = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index == focus) {
        continue;
      }

      natural += std::min(sizes[index].whole(metrics), metrics.inactive_maximum);
      shortest += std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
    }

    if (natural <= budget) {
      naturalWidths(result, sizes, metrics);

      return result;
    }

    const auto captioned = captionedTabs(sizes, focus, metrics, budget, shortest <= budget);
    distribute(result, sizes, captioned, metrics, budget);
    if (shortest > budget) {
      while (result.footprint(metrics) > room.width && result.end - result.first > 1) {
        if (result.end - 1 - focus >= focus - result.first) {
          --result.end;
        } else {
          ++result.first;
        }
      }
    }

    return result;
  }

private:
  using Captioned = std::array<bool, maximum_tabs>;

  static void naturalWidths(Plan &plan, std::span<const Measure> sizes, const Metrics &metrics) noexcept {
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != plan.focus) {
        plan.widths[index] = std::min(sizes[index].whole(metrics), metrics.inactive_maximum);
        plan.fits[index] = sizes[index].whole(metrics) <= metrics.inactive_maximum ? Fit::full : Fit::truncated;
      }
    }
  }

  [[nodiscard]] static Captioned captionedTabs(std::span<const Measure> sizes, std::size_t focus, const Metrics &metrics, float budget, bool all_fit) noexcept {
    Captioned captioned{};
    if (all_fit) {
      captioned.fill(true);
      captioned[focus] = false;

      return captioned;
    }

    float used = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != focus) {
        used += sizes[index].compact(metrics);
      }
    }

    for (std::size_t distance = 1; distance < sizes.size(); ++distance) {
      const std::array<std::optional<std::size_t>, 2> candidates{focus >= distance ? std::optional{focus - distance} : std::nullopt, focus + distance < sizes.size() ? std::optional{focus + distance} : std::nullopt};
      for (const auto candidate : candidates) {
        if (!candidate) {
          continue;
        }

        const auto index = *candidate;
        const auto extra = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum) - sizes[index].compact(metrics);
        if (used + extra <= budget) {
          captioned[index] = true;
          used += extra;
        }
      }
    }

    return captioned;
  }

  [[nodiscard]] static float largestCap(std::span<const Measure> sizes, const Captioned &captioned, const Metrics &metrics, float budget) noexcept {
    float low = 0;
    auto high = metrics.inactive_maximum;
    for (std::size_t iteration = 0; iteration < cap_iterations; ++iteration) {
      const auto cap = (low + high) / 2;
      float used = 0;
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        if (captioned[index]) {
          used += std::max(std::min(sizes[index].truncated(metrics), metrics.inactive_maximum), std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap}));
        }
      }

      if (used <= budget) {
        low = cap;
      } else {
        high = cap;
      }
    }

    return low;
  }

  static void distribute(Plan &plan, std::span<const Measure> sizes, const Captioned &captioned, const Metrics &metrics, float budget) noexcept {
    float fixed = 0;
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (index != plan.focus && !captioned[index]) {
        plan.widths[index] = sizes[index].compact(metrics);
        plan.fits[index] = Fit::compact;
        fixed += sizes[index].compact(metrics);
      }
    }

    const auto cap = largestCap(sizes, captioned, metrics, budget - fixed);
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      if (captioned[index]) {
        const auto minimum = std::min(sizes[index].truncated(metrics), metrics.inactive_maximum);
        const auto width = std::floor(std::max(minimum, std::min({sizes[index].whole(metrics), metrics.inactive_maximum, cap})));
        plan.widths[index] = width;
        plan.fits[index] = width >= sizes[index].whole(metrics) ? Fit::full : Fit::truncated;
      }
    }
  }
};

}
