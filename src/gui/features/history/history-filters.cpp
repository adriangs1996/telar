module telar.gui.features.history;

import std;

import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::history {

  tbc::val_static<HistoryEmpty> HistoryEmpty::derive(const HistoryEmptyOptions& options) {
    HistoryEmpty result;

    if (options.phase == HistoryPhase::loading && !options.has_page) {
      result.title.append("Searching your command history…");

      return result;
    }

    if (options.phase == HistoryPhase::failed) {
      result.title.append("Could not load the command history");

      return result;
    }

    result.emphasized = true;
    // Nothing of the person's own: the panel shows their commands alone by default, and what an
    // import brings is theirs.
    const auto nothing_recorded = !options.has_query && options.scope == HistoryScope::global && options.author != HistoryAuthorFilter::agent && !options.failed_only && options.page_offset == 0;
    if (nothing_recorded) {
      result.title.append("No commands yet");
      result.subtitle = "Commands you run in telar appear here as you work. Bring your shell history:";
      result.action = Action::import;

      return result;
    }

    result.subtitle = "Widen the search or check the filters.";
    result.action = options.scope == HistoryScope::global ? Action::none : Action::everywhere;
    switch (options.scope) {
    case HistoryScope::global:
      result.title.append("No matching commands");
      break;
    case HistoryScope::workspace: {
      constexpr std::string_view prefix = "No matches in workspace ";
      if (options.workspace.size() <= title_capacity - prefix.size()) {
        result.title.append(prefix);
        result.title.append(options.workspace);
      } else {
        result.title.append("No matches in this workspace");
      }

      break;
    }
    case HistoryScope::cwd:
      result.title.append("No matches in this directory");

      break;
    case HistoryScope::pane:
      result.title.append("No matches in this pane");

      break;
    }

    return result;
  }

  HistoryEmptyGeometry HistoryEmptyGeometry::derive(Rect area, ChromeMetrics chrome, HistoryEmptyMeasurements measured) noexcept {
    if (area.empty()) {
      return {};
    }

    const auto title_height = ChromeMetrics::lineHeight(chrome.body);
    const auto small_height = ChromeMetrics::lineHeight(chrome.small);
    const auto stack = title_height + chrome.px(title_gap) + small_height + chrome.px(action_gap) + chrome.px(action_height);
    const auto top = area.y + std::max(0.0F, (area.height - stack) / 2);
    const Rect inner{.x = area.x + chrome.px(side_inset), .y = top, .width = std::max(0.0F, area.width - chrome.px(side_inset * 2)), .height = title_height};
    const auto action_width = std::min(inner.width, measured.action == HistoryEmpty::Action::import ? measured.import + chrome.px(import_inset * 2) : chrome.px(search_width));
    const Rect subtitle{.x = inner.x, .y = inner.y + title_height + chrome.px(title_gap), .width = inner.width, .height = small_height};

    return {.title = centered(inner, measured.title), .subtitle = centered(subtitle, measured.subtitle), .action = {.x = inner.x + std::max(0.0F, (inner.width - action_width) / 2), .y = subtitle.y + small_height + chrome.px(action_gap), .width = action_width, .height = chrome.px(action_height)}};
  }

  Rect HistoryEmptyGeometry::centered(Rect area, float advance) noexcept {
    const auto width = std::min(area.width, advance);

    return {.x = area.x + std::max(0.0F, (area.width - width) / 2), .y = area.y, .width = width, .height = area.height};
  }

  float HistoryFilterChipGeometry::width(ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    auto result = measured.label + chrome.px(horizontal_padding * 2);

    if (measured.has_value) {
      result += measured.value + chrome.px(value_gap);
    }

    return result;
  }

  HistoryFilterChipGeometry HistoryFilterChipGeometry::derive(Rect bounds, ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    HistoryFilterChipGeometry result;

    result.bounds = bounds;
    result.label = {.x = bounds.x + chrome.px(horizontal_padding), .y = bounds.y, .width = std::max(0.0F, bounds.width - chrome.px(horizontal_padding * 2)), .height = bounds.height};
    const auto painted = result.label.empty() ? 0.0F : std::min(measured.label, result.label.width);
    const auto value_x = result.label.x + (painted + chrome.px(value_gap));

    result.value = {.x = value_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - chrome.px(horizontal_padding) - value_x), .height = bounds.height};

    return result;
  }

  template <std::size_t Count>
  float HistoryFilterGeometry::placeGroup(ds::Array<HistoryFilterChipGeometry, Count>& destination, Rect group, ChromeMetrics chrome, const ds::Array<HistoryFilterChipMeasurements, Count>& measured) noexcept {
    auto x = group.x + chrome.px(chip_inset);

    for (std::size_t index = 0; index < Count; ++index) {
      const auto width = HistoryFilterChipGeometry::width(chrome, measured[index]);

      destination.atMut(index) = HistoryFilterChipGeometry::derive({.x = x, .y = group.y + chrome.px(chip_inset), .width = width, .height = std::max(0.0F, group.height - chrome.px(chip_inset * 2))}, chrome, measured[index]);
      x += width + chrome.px(chip_inset);
    }

    return x + chrome.px(chip_inset);
  }

  HistoryFilterGeometry HistoryFilterGeometry::derive(Rect area, ChromeMetrics chrome, const HistoryFilterMeasurements& measured) noexcept {
    HistoryFilterGeometry result;

    if (area.empty()) {
      return result;
    }

    result.visible = true;
    result.separator = {.x = area.x, .y = area.bottom() - separator_height, .width = area.width, .height = separator_height};
    const auto height = std::min(chrome.px(maximum_chip_height), std::max(0.0F, area.height - chrome.px(vertical_inset)));
    const auto y = area.y + std::floor((area.height - height) / 2);
    auto scope_total = chrome.px(group_padding);
    auto author_total = chrome.px(group_padding);

    for (const auto& chip : measured.scopes) {
      scope_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }

    for (const auto& chip : measured.authors) {
      author_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }

    const auto failed_width = HistoryFilterChipGeometry::width(chrome, {.label = measured.failed});
    const auto gap = chrome.px(group_gap);
    const auto key_spacing = chrome.px(key_gap);
    const auto scope_key_width = measured.keys[0] + key_spacing;
    const auto author_key_width = measured.keys[1] + key_spacing;
    const auto failed_key_width = measured.keys[2] + key_spacing;
    const auto available = area.width - chrome.px(horizontal_inset * 2);
    const auto with_keys = scope_total + scope_key_width + gap + author_total + author_key_width + gap + failed_width + failed_key_width;

    result.show_keys = with_keys <= available;
    result.show_right = result.show_keys || scope_total + gap + author_total + gap + failed_width <= available;

    const auto left = area.x + chrome.px(horizontal_inset);

    result.scope_group = {.x = left, .y = y, .width = scope_total, .height = height};
    const auto scope_end = placeGroup(result.scopes, result.scope_group, chrome, measured.scopes);

    if (result.show_keys) {
      result.keys.atMut(0) = {.x = scope_end + key_spacing, .y = y, .width = scope_key_width, .height = height};
    }

    if (!result.show_right) {
      return result;
    }

    auto right = area.right() - chrome.px(horizontal_inset);

    if (result.show_keys) {
      right -= failed_key_width;
      result.keys.atMut(2) = {.x = right + key_spacing, .y = y, .width = failed_key_width, .height = height};
    }

    right -= failed_width;
    result.failed = HistoryFilterChipGeometry::derive({.x = right, .y = y, .width = failed_width, .height = height}, chrome, {.label = measured.failed});
    right -= gap;
    if (result.show_keys) {
      right -= author_key_width;
      result.keys.atMut(1) = {.x = right + key_spacing, .y = y, .width = author_key_width, .height = height};
    }

    right -= author_total;
    result.author_group = {.x = right, .y = y, .width = author_total, .height = height};
    placeGroup(result.authors, result.author_group, chrome, measured.authors);

    return result;
  }

}
