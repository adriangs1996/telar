#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct HistoryRowMeasurements {
  float command = 0;
  float cwd = 0;
  float time = 0;
  bool agent = false;
  bool show_cwd = true;
  bool has_cwd = false;
  bool has_time = false;
  bool expanded = false;
};

struct HistoryRowGeometry {
  static constexpr float horizontal_inset = 8;
  static constexpr float vertical_inset = 1;
  static constexpr float status_inset = 10;
  static constexpr float status_width = 20;
  static constexpr float command_inset = 40;
  static constexpr float right_inset = 12;
  static constexpr float fact_gap = 14;
  static constexpr float provider_side = 16;
  static constexpr float minimum_command = 160;
  static constexpr float corner_radius = 8;
  static constexpr float heading_inset = 18;
  static constexpr float provider_radius = 3;
  static constexpr float selection_tint_alpha = 0.08F;
  static constexpr float selection_ring_alpha = 0.28F;
  static constexpr float hover_alpha = 0.6F;
  static constexpr float cwd_alpha = 0.8F;

  Rect frame;
  Rect status;
  Rect command;
  Rect provider;
  Rect cwd;
  Rect time;

  [[nodiscard]] static HistoryRowGeometry derive(Rect bounds, ChromeMetrics chrome, float row_height, HistoryRowMeasurements measurements) noexcept {
    HistoryRowGeometry result;
    result.frame = bounds.inset(chrome.px(horizontal_inset), chrome.px(vertical_inset));
    const auto line_x = result.frame.x + chrome.px(command_inset);
    const Rect line{.x = line_x, .y = result.frame.y, .width = std::max(0.0F, result.frame.right() - chrome.px(right_inset) - line_x), .height = std::max(0.0F, row_height - chrome.px(2 * vertical_inset))};
    result.status = {.x = result.frame.x + chrome.px(status_inset), .y = line.y, .width = chrome.px(status_width), .height = line.height};
    const auto gap = chrome.px(fact_gap);
    Facts facts;
    if (measurements.agent) {
      facts.append(Kind::provider, std::round(chrome.px(provider_side)), gap);
    }

    if (!measurements.expanded && measurements.show_cwd && measurements.has_cwd) {
      facts.append(Kind::cwd, measurements.cwd, gap);
    }

    if (measurements.has_time) {
      facts.append(Kind::time, measurements.time, gap);
    }

    if (!measurements.expanded && measurements.command + facts.width > line.width) {
      facts.removeCwd(gap);
    }

    while (facts.count > 0 && facts.width - gap > line.width - chrome.px(minimum_command)) {
      facts.remove(facts.count - 1, gap);
    }

    facts.width = std::max(0.0F, facts.width - gap);
    result.command = line;
    const auto reserved = facts.count == 0 ? 0 : facts.width + gap;
    result.command.width = std::max(0.0F, line.width - reserved);
    auto x = line.right() - facts.width;
    for (std::size_t index = 0; index < facts.count; ++index) {
      const auto token = facts.tokens[index];
      const Rect area{.x = x, .y = line.y, .width = token.width, .height = line.height};
      switch (token.kind) {
      case Kind::provider:
        result.provider = {.x = x, .y = line.y + std::floor((line.height - token.width) / 2), .width = token.width, .height = token.width};
        break;
      case Kind::cwd:
        result.cwd = area;
        break;
      case Kind::time:
        result.time = area;
        break;
      }

      x += token.width + gap;
    }

    return result;
  }

  bool operator==(const HistoryRowGeometry &) const = default;

private:
  enum class Kind : std::uint8_t {
    provider,
    cwd,
    time,
  };

  struct Token {
    Kind kind = Kind::provider;
    float width = 0;
  };

  struct Facts {
    static constexpr std::size_t capacity = 3;
    std::array<Token, capacity> tokens{};
    std::size_t count = 0;
    float width = 0;

    void append(Kind kind, float advance, float gap) noexcept {
      tokens[count++] = {.kind = kind, .width = advance};
      width += advance + gap;
    }

    void remove(std::size_t index, float gap) noexcept {
      width -= tokens[index].width + gap;
      for (auto next = index + 1; next < count; ++next) {
        tokens[next - 1] = tokens[next];
      }

      --count;
    }

    void removeCwd(float gap) noexcept {
      for (std::size_t index = 0; index < count; ++index) {
        if (tokens[index].kind == Kind::cwd) {
          remove(index, gap);

          return;
        }
      }
    }
  };
};

}
