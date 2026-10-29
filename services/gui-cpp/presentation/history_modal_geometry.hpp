#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>
#include <cmath>
#include <initializer_list>

namespace telar::gui {

struct HistoryModalMetrics {
  Rect viewport{};
  ChromeMetrics chrome{};
  float cell_height = 0;
};

struct HistoryModalGeometry {
  static constexpr float maximum_width = 1360;
  static constexpr float minimum_height = 640;
  static constexpr float height_share = 0.8F;
  static constexpr float split_width = 900;
  static constexpr float list_share = 0.44F;
  static constexpr float margin = 28;
  static constexpr float margin_divisor = 12;
  static constexpr float row_minimum = 34;
  static constexpr float row_padding = 12;
  static constexpr float group_minimum = 28;
  static constexpr float group_padding = 10;
  static constexpr float header_minimum = 46;
  static constexpr float header_padding = 22;
  static constexpr float search_minimum = 52;
  static constexpr float search_padding = 24;
  static constexpr float footer_minimum = 36;
  static constexpr float footer_padding = 14;
  static constexpr float compact_width = 420;
  static constexpr float compact_height = 260;
  static constexpr float inspection_inset = 18;
  static constexpr float inspection_inset_divisor = 8;
  static constexpr float action_minimum = 28;
  static constexpr float action_padding = 8;

  Rect viewport;
  Rect bounds;
  Rect header;
  Rect results;
  Rect inspection;
  Rect search;
  Rect footer;
  float row_height = 0;
  float group_height = 0;
  bool compact = false;

  [[nodiscard]] static HistoryModalGeometry measure(const HistoryModalMetrics &metrics, bool inspecting) noexcept {
    const auto &chrome = metrics.chrome;
    const auto viewport = metrics.viewport;
    const auto inset = std::min(chrome.px(margin), std::min(viewport.width, viewport.height) / margin_divisor);
    const auto width = std::max(0.0F, std::min(chrome.px(maximum_width), viewport.width - (inset * 2)));
    const auto line_height = std::max(ChromeMetrics::lineHeight(chrome.body), metrics.cell_height);
    const auto row_height = std::max(chrome.px(row_minimum), line_height + chrome.px(row_padding));
    const auto group_height = std::max(chrome.px(group_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(group_padding));
    const auto header_height = std::max(chrome.px(header_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(header_padding));
    const auto search_height = std::max(chrome.px(search_minimum), line_height + chrome.px(search_padding));
    const auto footer_height = std::max(chrome.px(footer_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(footer_padding));
    const auto available = viewport.height - chrome.status_bar - (inset * 2);
    const auto height = std::max(0.0F, std::min(available, std::max(chrome.px(minimum_height), viewport.height * height_share)));
    const Rect bounds{
        .x = std::floor((viewport.width - width) / 2),
        .y = std::floor(std::max(0.0F, std::min(viewport.height - height, viewport.height - chrome.status_bar - inset - height))),
        .width = width,
        .height = height,
    };
    const auto compact = width < chrome.px(compact_width) || height < chrome.px(compact_height);
    auto content = bounds;
    const auto footer = takeBottom(content, footer_height);
    const auto search = takeBottom(content, search_height);
    const auto header = takeTop(content, compact ? 0 : header_height);
    auto list = content;
    Rect inspection{.x = content.x, .y = content.y};
    if (inspecting) {
      inspection = content;
      if (width >= chrome.px(split_width)) {
        list.width = std::floor(content.width * list_share);
        inspection.x = list.x + list.width;
        inspection.width = std::max(0.0F, content.width - list.width);
      } else {
        list.width = 0;
      }
    }

    return {.viewport = viewport, .bounds = bounds, .header = header, .results = list, .inspection = inspection, .search = search, .footer = footer, .row_height = row_height, .group_height = group_height, .compact = compact};
  }

  void offsetY(float offset) noexcept {
    for (auto *area : {&bounds, &header, &results, &inspection, &search, &footer}) {
      area->y += offset;
    }
  }

  [[nodiscard]] Rect inspectionContent(const ChromeMetrics &chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto actions = inspectionActions(chrome);

    return {.x = inspection.x + inset, .y = inspection.y + inset, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = std::max(0.0F, actions.y - inspection.y - (inset * 2))};
  }

  [[nodiscard]] Rect inspectionActions(const ChromeMetrics &chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto height = std::min(std::max(chrome.px(action_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(action_padding)), std::max(0.0F, inspection.height - (inset * 2)));

    return {.x = inspection.x + inset, .y = inspection.y + inspection.height - inset - height, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = height};
  }

private:
  [[nodiscard]] float inspectionInset(const ChromeMetrics &chrome) const noexcept {
    return std::min(chrome.px(inspection_inset), std::min(inspection.width, inspection.height) / inspection_inset_divisor);
  }

  static Rect takeBottom(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    remaining.height -= taken;

    return {.x = remaining.x, .y = remaining.y + remaining.height, .width = remaining.width, .height = taken};
  }

  static Rect takeTop(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect top{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};
    remaining.y += taken;
    remaining.height -= taken;

    return top;
  }
};

}
