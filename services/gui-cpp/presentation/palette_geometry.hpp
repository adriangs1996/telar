#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>

namespace telar::gui {

struct PaletteGeometry {
  struct Options {
    std::optional<std::uint16_t> pick_rows;
    bool suggest = false;
  };

  static constexpr float maximum_width = 640;
  static constexpr float margin = 24;
  static constexpr float margin_divisor = 12;
  static constexpr float top_share = 0.11F;
  static constexpr float row_minimum = 38;
  static constexpr float row_padding = 16;
  static constexpr float agent_minimum = 52;
  static constexpr float agent_padding = 12;
  static constexpr float group_minimum = 28;
  static constexpr float group_padding = 10;
  static constexpr float heading_minimum = 32;
  static constexpr float heading_padding = 12;
  static constexpr float search_minimum = 60;
  static constexpr float search_padding = 24;
  static constexpr float tabs_minimum = 38;
  static constexpr float tabs_padding = 16;
  static constexpr float footer_minimum = 40;
  static constexpr float footer_padding = 16;
  static constexpr float list_padding = 22;
  static constexpr float pick_padding = 16;
  static constexpr float suggestion_height = 180;
  static constexpr std::uint16_t minimum_pick_rows = 3;
  static constexpr std::uint16_t maximum_pick_rows = 8;
  static constexpr float heading_divisor = 6;
  static constexpr float search_divisor = 2;
  static constexpr float tabs_divisor = 4;
  static constexpr float footer_divisor = 3;

  Rect viewport;
  Rect bounds;
  Rect heading;
  Rect search;
  Rect tabs;
  Rect results;
  Rect footer;
  float row_height = 0;
  float agent_height = 0;
  float group_height = 0;

  [[nodiscard]] static PaletteGeometry measure(Rect viewport, const ChromeMetrics &chrome, Options options) noexcept {
    const auto inset = std::min(chrome.px(margin), std::min(viewport.width, viewport.height) / margin_divisor);
    const auto width = std::max(0.0F, std::min(chrome.px(maximum_width), viewport.width - (inset * 2)));
    const auto row_height = std::max(chrome.px(row_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(row_padding));
    const auto agent_height = std::max(chrome.px(agent_minimum), ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(agent_padding));
    const auto group_height = std::max(chrome.px(group_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(group_padding));
    const bool nested = options.pick_rows.has_value() || options.suggest;
    const auto heading_height = nested ? std::max(chrome.px(heading_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(heading_padding)) : 0;
    const auto search_height = std::max(chrome.px(search_minimum), ChromeMetrics::lineHeight(chrome.title) + chrome.px(search_padding));
    const auto tabs_height = nested ? 0 : std::max(chrome.px(tabs_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(tabs_padding));
    const auto footer_height = std::max(chrome.px(footer_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(footer_padding));
    auto list_height = (row_height * maximum_pick_rows) + chrome.px(list_padding);
    if (options.suggest) {
      list_height = chrome.px(suggestion_height);
    } else if (options.pick_rows) {
      list_height = (row_height * static_cast<float>(std::clamp(*options.pick_rows, minimum_pick_rows, maximum_pick_rows))) + chrome.px(pick_padding);
    }

    const auto height = std::max(0.0F, std::min(heading_height + search_height + tabs_height + list_height + footer_height, viewport.height - (inset * 2)));
    const auto top = std::min(std::max(inset, viewport.height * top_share), std::max(inset, viewport.height - inset - height));
    const Rect bounds{.x = std::floor((viewport.width - width) / 2), .y = std::floor(top), .width = width, .height = height};
    auto rest = bounds;
    const auto heading = takeTop(rest, std::min(heading_height, height / heading_divisor));
    const auto search = takeTop(rest, std::min(search_height, rest.height / search_divisor));
    const auto tabs = takeTop(rest, std::min(tabs_height, rest.height / tabs_divisor));
    const auto footer_size = std::min(footer_height, rest.height / footer_divisor);
    const auto results = takeTop(rest, rest.height - footer_size);

    return {.viewport = viewport, .bounds = bounds, .heading = heading, .search = search, .tabs = tabs, .results = results, .footer = rest, .row_height = row_height, .agent_height = agent_height, .group_height = group_height};
  }

  [[nodiscard]] static Rect inset(Rect bounds, float amount) noexcept {
    const auto x = std::min(amount, bounds.width / 2);
    const auto y = std::min(amount, bounds.height / 2);

    return {.x = bounds.x + x, .y = bounds.y + y, .width = std::max(0.0F, bounds.width - (x * 2)), .height = std::max(0.0F, bounds.height - (y * 2))};
  }

private:
  static Rect takeTop(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect result{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};
    remaining.y += taken;
    remaining.height -= taken;

    return result;
  }
};

}
