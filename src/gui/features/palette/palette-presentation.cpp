module telar.gui.features.palette;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::palette {

  PaletteGeometry PaletteGeometry::measure(Rect viewport, const ChromeMetrics& chrome, Options options) noexcept {
    const auto inset = std::min(chrome.px(margin), std::min(viewport.width, viewport.height) / margin_divisor);
    const auto width = std::max(0.0F, std::min(chrome.px(maximum_width), viewport.width - (inset * 2)));
    const auto row_height = std::max(chrome.px(row_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(row_padding));
    const auto agent_height = std::max(chrome.px(agent_minimum), ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(agent_padding));
    const auto group_height = std::max(chrome.px(group_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(group_padding));
    const bool nested = options.pick_rows.hasValue() || options.suggest;
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

  Rect PaletteGeometry::inset(Rect bounds, float amount) noexcept {
    const auto x = std::min(amount, bounds.width / 2);
    const auto y = std::min(amount, bounds.height / 2);

    return {.x = bounds.x + x, .y = bounds.y + y, .width = std::max(0.0F, bounds.width - (x * 2)), .height = std::max(0.0F, bounds.height - (y * 2))};
  }

  Rect PaletteGeometry::takeTop(Rect& remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect result{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};

    remaining.y += taken;
    remaining.height -= taken;

    return result;
  }

  PaletteRowWindow PaletteRowWindow::measure(std::span<const PaletteRowKind> kinds, std::size_t selection, const PaletteGeometry& geometry, const ChromeMetrics& chrome, bool grouped) noexcept {
    PaletteRowWindow result;

    if (kinds.empty()) {
      return result;
    }

    const auto bounds = PaletteGeometry::inset(geometry.results, chrome.px(content_inset));
    const auto selected = std::min(selection, kinds.size() - 1);
    auto start = selected;
    auto used = rowHeight(kinds[selected], geometry) + (grouped ? geometry.group_height : 0);

    while (start != 0 && selected - start + 1 < capacity) {
      const auto preceding = start - 1;
      const auto extra = rowHeight(kinds[preceding], geometry) + (grouped && kinds[preceding] != kinds[start] ? geometry.group_height : 0);
      if (used + extra > bounds.height) {
        break;
      }

      start = preceding;
      used += extra;
    }

    result.first = start;
    auto y = bounds.y;
    ds::Option<PaletteRowKind> previous;

    for (auto index = start; index < kinds.size() && result.count < capacity; ++index) {
      const auto height = rowHeight(kinds[index], geometry);
      Rect group;

      if (grouped && previous != kinds[index]) {
        if (y + geometry.group_height + height > bounds.bottom()) {
          break;
        }

        group = {.x = bounds.x, .y = y, .width = bounds.width, .height = geometry.group_height};
        y += geometry.group_height;
        previous = kinds[index];
      }

      if (y + height > bounds.bottom()) {
        break;
      }

      result.rows.atMut(result.count++) = {.index = index, .group = group, .bounds = {.x = bounds.x, .y = y, .width = bounds.width, .height = height}};
      y += height;
    }

    return result;
  }

  float PaletteRowWindow::rowHeight(PaletteRowKind kind, const PaletteGeometry& geometry) noexcept {
    return kind == PaletteRowKind::agent ? geometry.agent_height : geometry.row_height;
  }

  SuggestionGeometry SuggestionGeometry::measure(const PaletteGeometry& palette, const ChromeMetrics& chrome, bool has_parent) noexcept {
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

  std::string_view SuggestionLabels::heading(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Start with a task";
    case SuggestionPhase::waiting:
      return "Generating a command…";
    case SuggestionPhase::ready:
      return "Suggested command";
    case SuggestionPhase::failed:
      return "Could not generate a command";
    }

    return {};
  }

  std::string_view SuggestionLabels::message(SuggestionPhase phase, SuggestionStatus status) noexcept {
    if (phase == SuggestionPhase::idle) {
      return "Describe the command you need, then press Enter.";
    }

    if (phase == SuggestionPhase::waiting) {
      return "Keep editing or press Esc to cancel.";
    }

    if (phase == SuggestionPhase::ready) {
      return {};
    }

    switch (status) {
    case SuggestionStatus::ready:
      return "The engine returned no command. Try again.";
    case SuggestionStatus::unavailable:
      return "Configure runtime.engine to enable suggestions.";
    case SuggestionStatus::timeout:
      return "The engine timed out. Try again.";
    case SuggestionStatus::failed:
      return "The engine could not answer. Try again.";
    }

    return {};
  }

  std::string_view SuggestionLabels::button(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Generate  ↵";
    case SuggestionPhase::waiting:
      return "Generating…";
    case SuggestionPhase::ready:
      return "Paste command  ↵";
    case SuggestionPhase::failed:
      return "Try again  ↵";
    }

    return {};
  }

  std::string_view SuggestionLabels::footer(SuggestionPhase phase) noexcept {
    return phase == SuggestionPhase::ready ? "Paste first, then run in shell." : "Review before pasting.";
  }

  bool SuggestionLabels::canSubmit(SuggestionPhase phase, std::string_view query) noexcept {
    return phase != SuggestionPhase::waiting && (phase == SuggestionPhase::ready || !query.empty());
  }

}
