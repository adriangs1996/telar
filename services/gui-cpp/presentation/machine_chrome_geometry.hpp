#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "machines/limits.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui {

struct MachineChromeGeometry {
  static constexpr float switcher_disc = 7;
  static constexpr float switcher_padding = 8;
  static constexpr float switcher_gap = 4;
  static constexpr float maximum_control = 120;
  static constexpr float segment_disc = 8;
  static constexpr float segment_padding = 10;
  static constexpr float segment_gap = 6;
  static constexpr float maximum_segment = 200;
  static constexpr float attention_diameter = 6;
  static constexpr float attention_gap = 6;

  enum class Kind : std::uint8_t {
    switcher,
    segment,
    fold,
  };

  struct Row {
    std::array<Rect, MachineLimits::window_slots> controls{};
    std::size_t count = 0;
    std::size_t hidden = 0;
    Rect fold;
  };

  struct Control {
    Rect bounds;
    Rect label;
    Rect disc;
    Rect attention;
    float radius = 0;
  };

  [[nodiscard]] static Row switcher(Rect area, const ChromeMetrics &chrome, std::span<const float> advances, float more_advance) {
    if (advances.size() > MachineLimits::window_slots) {
      throw std::length_error{"TooManyMachineControls"};
    }

    Row row;
    if (advances.size() <= 1 || area.empty()) {
      return row;
    }

    const auto more_reserve = more_advance + chrome.px(2 * switcher_padding);
    auto left = area.x;
    for (const auto advance : advances) {
      const auto width = switcherControlWidth(chrome, advance);
      if (row.hidden != 0 || left + width > area.right() - more_reserve) {
        ++row.hidden;
        continue;
      }

      row.controls[row.count++] = {.x = left, .y = area.y, .width = width, .height = area.height};
      left += width + chrome.px(switcher_gap);
    }

    if (row.hidden != 0) {
      row.fold = {.x = left, .y = area.y, .width = std::max(0.0F, std::min(more_reserve, area.right() - left)), .height = area.height};
    }

    return row;
  }

  [[nodiscard]] static float switcherControlWidth(const ChromeMetrics &chrome, float advance) noexcept {
    return std::min(advance + chrome.px((2 * switcher_padding) + switcher_disc + switcher_gap), chrome.px(maximum_control));
  }

  [[nodiscard]] static float preferredSwitcher(const ChromeMetrics &chrome, std::span<const float> advances, float more_advance) {
    if (advances.size() > MachineLimits::window_slots) {
      throw std::length_error{"TooManyMachineControls"};
    }

    if (advances.size() <= 1) {
      return 0;
    }

    float width = more_advance + chrome.px(2 * switcher_padding);
    for (const auto advance : advances) {
      width += switcherControlWidth(chrome, advance) + chrome.px(switcher_gap);
    }

    return width - chrome.px(switcher_gap);
  }

  [[nodiscard]] static float preferredSegment(const ChromeMetrics &chrome, float advance) noexcept {
    return std::min(advance + chrome.px(segment_disc + segment_gap + (2 * segment_padding)), chrome.px(maximum_segment));
  }

  [[nodiscard]] static Control control(Rect area, const ChromeMetrics &chrome, Kind kind, float advance, bool attention) noexcept {
    if (area.empty()) {
      return {};
    }

    const bool segment = kind == Kind::segment;
    const bool fold = kind == Kind::fold;
    const auto side = chrome.px(segment ? segment_disc : switcher_disc);
    const auto padding = chrome.px(segment ? segment_padding : switcher_padding);
    const auto gap = chrome.px(segment ? segment_gap : switcher_gap);
    const auto dot_space = attention ? chrome.px(attention_diameter + attention_gap) : 0;
    const auto inset = fold ? dot_space : padding + side + gap;
    Control result;
    result.bounds = area;
    result.label = {.x = area.x + inset, .y = area.y, .width = std::max(0.0F, area.width - (2 * inset) - (fold ? 0 : dot_space)), .height = area.height};
    result.radius = area.height / 2;
    if (fold) {
      const auto width = std::min(result.label.width, advance);
      result.label.x += std::floor((result.label.width - width) / 2);
      result.label.width = width;
    } else {
      result.disc = {.x = area.x + padding, .y = area.y + ((area.height - side) / 2), .width = side, .height = side};
    }

    if (attention) {
      const auto diameter = chrome.px(attention_diameter);
      result.attention = {.x = std::max(area.x, area.right() - chrome.px(attention_gap) - diameter), .y = area.y + std::max(0.0F, (area.height - diameter) / 2), .width = std::min(diameter, area.width), .height = std::min(diameter, area.height)};
    }

    return result;
  }
};

}
