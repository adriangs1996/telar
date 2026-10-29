#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "palette_geometry.hpp"
#include <algorithm>

namespace telar::gui {

struct SuggestionGeometry {
  static constexpr float content_inset = 18;
  static constexpr float heading_padding = 8;
  static constexpr float body_gap = 8;
  static constexpr float preview_inset = 12;
  static constexpr float preview_radius = 6;
  static constexpr float button_width = 170;
  static constexpr float footer_inset = 14;
  static constexpr float button_vertical_inset = 4;
  static constexpr float footer_gap_count = 3;
  static constexpr float footer_separator_height = 1;
  static constexpr float message_alpha = 0.65F;
  static constexpr float title_alpha = 0.75F;
  static constexpr float title_inset = 8;
  static constexpr float back_width = 26;

  Rect title;
  Rect back;
  Rect heading;
  Rect body;
  Rect message;
  Rect preview;
  Rect footer_caption;
  Rect button;
  Rect separator;

  [[nodiscard]] static SuggestionGeometry measure(const PaletteGeometry &palette, const ChromeMetrics &chrome, bool has_parent) noexcept {
    auto title = PaletteGeometry::inset(palette.heading, chrome.px(title_inset));
    Rect back;
    if (has_parent) {
      const auto width = std::min(title.width, chrome.px(back_width));
      back = {.x = title.x, .y = palette.heading.y, .width = width, .height = palette.heading.height};
      title.x += width;
      title.width -= width;
    }

    const auto results = palette.results;
    const auto footer = palette.footer;
    const auto content = PaletteGeometry::inset(results, chrome.px(content_inset));
    const auto heading_height = std::min(content.height, ChromeMetrics::lineHeight(chrome.body) + chrome.px(heading_padding));
    const Rect heading{.x = content.x, .y = content.y, .width = content.width, .height = heading_height};
    const auto gap = chrome.px(body_gap);
    const Rect body{.x = content.x, .y = content.y + heading_height + gap, .width = content.width, .height = std::max(0.0F, content.height - heading_height - gap)};
    auto message = body;
    message.height = std::min(body.height, ChromeMetrics::lineHeight(chrome.body));
    const auto width = std::min(chrome.px(button_width), footer.width / 2);
    const auto inset = std::min(chrome.px(footer_inset), footer.width / 8);
    const Rect button{.x = footer.right() - width - inset, .y = footer.y + chrome.px(button_vertical_inset), .width = width, .height = std::max(0.0F, footer.height - chrome.px(button_vertical_inset * 2))};

    return {
        .title = title,
        .back = back,
        .heading = heading,
        .body = body,
        .message = message,
        .preview = PaletteGeometry::inset(body, chrome.px(preview_inset)),
        .footer_caption = {.x = footer.x + inset, .y = footer.y, .width = std::max(0.0F, footer.width - width - (inset * footer_gap_count)), .height = footer.height},
        .button = button,
        .separator = {.x = footer.x, .y = footer.y, .width = footer.width, .height = std::min(chrome.px(footer_separator_height), footer.height)},
    };
  }
};

}
