#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_filter_chip_geometry.hpp"
#include "presentation/history_filter_geometry.hpp"
#include "presentation/history_filter_labels.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <string_view>

namespace {

using namespace telar::gui;

enum class Event : std::uint8_t {
  end,
  fill,
  rounded,
  ring,
  text,
};

struct ChipStyle {
  std::string_view label;
  std::string_view value;
  bool selected = false;
  bool danger = false;
  bool hovered = false;
};

struct TextLabel {
  std::string_view text;
  std::string_view color;
  bool mono = false;
};

void rounded(Rect area, float radius, std::string_view color) {
  probe::write(Event::rounded);
  probe::writeRect(area);
  probe::write(radius);
  probe::writeText(color);
}

void text(Rect area, TextLabel label) {
  if (area.empty()) {
    return;
  }

  probe::write(Event::text);
  probe::writeRect(area);
  probe::writeText(label.text);
  probe::writeText(label.color);
  probe::write(static_cast<std::uint8_t>(!label.mono));
  probe::write(static_cast<std::uint8_t>(!label.mono));
}

void chip(const HistoryFilterChipGeometry &geometry, ChromeMetrics chrome, ChipStyle style) {
  if (style.selected || style.hovered) {
    rounded(geometry.bounds, chrome.px(HistoryFilterChipGeometry::corner_radius), "surface1");
  }
  if (style.danger && style.selected) {
    probe::write(Event::ring);
    probe::writeRect(geometry.bounds);
    probe::write(HistoryFilterChipGeometry::danger_ring_alpha);
    probe::write(chrome.px(HistoryFilterChipGeometry::ring_width));
    probe::write(chrome.px(HistoryFilterChipGeometry::corner_radius));
    probe::writeText("red");
  }

  std::string_view color = style.selected ? "text" : "subtext0";
  if (style.danger && style.selected) {
    color = "red";
  }

  text(geometry.label, {.text = style.label, .color = color});
  if (!style.value.empty()) {
    text(geometry.value, {.text = style.value, .color = "accent"});
  }
}

void filters(SystemAllocator &memory) {
  const auto area = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  const auto style = probe::read<HistoryKeyStyle>();
  const auto flags = probe::read<std::uint8_t>();
  const auto scope = probe::read<std::uint8_t>();
  const auto author = probe::read<std::uint8_t>();
  const auto hover = probe::read<std::uint8_t>();
  const auto value = probe::readText(memory);
  HistoryFilterMeasurements measured;
  for (auto &entry : measured.scopes) {
    entry.label = probe::read<float>();
  }

  const auto value_width = probe::read<float>();
  for (std::size_t index = 0; index < measured.scopes.size(); ++index) {
    measured.scopes[index].has_value = index == scope && !value.empty();
    measured.scopes[index].value = measured.scopes[index].has_value ? value_width : 0;
  }
  for (auto &entry : measured.authors) {
    entry.label = probe::read<float>();
  }
  measured.failed = probe::read<float>();
  for (auto &key : measured.keys) {
    key = probe::read<float>();
  }

  const auto geometry = HistoryFilterGeometry::derive(area, chrome, measured);
  if (!geometry.visible) {
    probe::write(Event::end);

    return;
  }

  probe::write(Event::fill);
  probe::writeRect(geometry.separator);
  probe::writeText("surface1");
  rounded(geometry.scope_group, chrome.px(HistoryFilterGeometry::group_radius), "surface0");
  for (std::size_t index = 0; index < geometry.scopes.size(); ++index) {
    chip(geometry.scopes[index], chrome, {.label = HistoryFilterLabels::scopes[index].text, .value = index == scope ? std::string_view{value} : std::string_view{}, .selected = index == scope, .hovered = hover == index + 1});
  }

  const auto keys = HistoryFilterLabels::keys(style);
  if (geometry.show_keys) {
    text(geometry.keys[0], {.text = keys[0], .color = "overlay1", .mono = true});
  }
  if (geometry.show_right) {
    if (geometry.show_keys) {
      text(geometry.keys[2], {.text = keys[2], .color = "overlay1", .mono = true});
    }
    chip(geometry.failed, chrome, {.label = HistoryFilterLabels::failed, .value = {}, .selected = flags != 0, .danger = true, .hovered = hover == HistoryFilterLabels::scopes.size() + HistoryFilterLabels::authors.size() + 1});
    if (geometry.show_keys) {
      text(geometry.keys[1], {.text = keys[1], .color = "overlay1", .mono = true});
    }
    rounded(geometry.author_group, chrome.px(HistoryFilterGeometry::group_radius), "surface0");
    for (std::size_t index = 0; index < geometry.authors.size(); ++index) {
      chip(geometry.authors[index], chrome, {.label = HistoryFilterLabels::authors[index].text, .value = {}, .selected = index == author, .hovered = hover == HistoryFilterLabels::scopes.size() + index + 1});
    }
  }

  probe::write(Event::end);
}

}

int main() {
  try {
    telar::gui::SystemAllocator memory;
    while (std::fgetc(stdin) != EOF) {
      filters(memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
