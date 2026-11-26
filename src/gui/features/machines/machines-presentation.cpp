module telar.gui.features.machines;

import std;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::machines {

  std::string_view MachineFacts::glyph(MachinePhase phase, bool attention) noexcept {
    if (attention || phase == MachinePhase::connected) {
      return "●";
    }

    switch (phase) {
    case MachinePhase::connecting:
      return "◌";
    case MachinePhase::lost:
    case MachinePhase::failed:
      return "✕";
    case MachinePhase::stopped:
      return "○";
    case MachinePhase::connected:
      break;
    }

    return {};
  }

  PaletteRole MachineFacts::glyphInk(MachinePhase phase, bool attention) noexcept {
    if (attention) {
      return PaletteRole::yellow;
    }

    switch (phase) {
    case MachinePhase::connected:
      return PaletteRole::green;
    case MachinePhase::connecting:
      return PaletteRole::overlay1;
    case MachinePhase::lost:
      return PaletteRole::peach;
    case MachinePhase::failed:
      return PaletteRole::red;
    case MachinePhase::stopped:
      return PaletteRole::overlay0;
    }

    return PaletteRole::text;
  }

  std::string_view MachineFacts::phaseName(MachinePhase phase) noexcept {
    switch (phase) {
    case MachinePhase::connected:
      return "connected";
    case MachinePhase::connecting:
      return "connecting";
    case MachinePhase::lost:
      return "lost";
    case MachinePhase::failed:
      return "failed";
    case MachinePhase::stopped:
      return "stopped";
    }

    return {};
  }

  MachineFacts::CpuText MachineFacts::cpu(MachinePhase phase, ds::Option<std::uint8_t> percent) {
    CpuText value;

    if (phase == MachinePhase::connected && percent) {
      value.appendDecimal(*percent);
      value.append("%");
    }

    return value;
  }

  float MachineFacts::width(const ChromeMetrics& chrome, Widths parts) noexcept {
    return parts.glyph + chrome.px(part_gap) + parts.label + (parts.cpu > 0 ? chrome.px(part_gap) + parts.cpu : 0);
  }

  MachineFacts::Geometry MachineFacts::geometry(Rect area, const ChromeMetrics& chrome, Widths parts) noexcept {
    Geometry result;

    result.bounds = {.x = area.x, .y = area.y, .width = width(chrome, parts), .height = area.height};
    result.glyph = {.x = area.x, .y = area.y, .width = parts.glyph, .height = area.height};
    result.label = {.x = result.glyph.right() + chrome.px(part_gap), .y = area.y, .width = parts.label, .height = area.height};
    if (parts.cpu > 0) {
      result.cpu = {.x = result.label.right() + chrome.px(part_gap), .y = area.y, .width = parts.cpu, .height = area.height};
    }

    return result;
  }

  std::string_view MachineChromeGeometry::listStatus(bool live, std::size_t agents, std::span<char, list_status_capacity> storage) noexcept {
    if (!live) {
      return "Offline";
    }

    if (agents == 0) {
      return {};
    }

    if (agents == 1) {
      return "1 active agent";
    }

    constexpr std::string_view suffix = " active agents";
    auto* const last = std::to_address(storage.end());
    const auto [end, error] = std::to_chars(storage.data(), last, agents);
    if (error == std::errc::value_too_large || static_cast<std::size_t>(last - end) < suffix.size()) {
      // A count too long for the storage is left out.
      return "active agents";
    }

    std::ranges::copy(suffix, end);

    return {storage.data(), static_cast<std::size_t>(end - storage.data()) + suffix.size()};
  }

  std::string_view MachineChromeGeometry::shownLabel(std::string_view label) noexcept {
    constexpr std::string_view link_local = ".local";

    if (label.size() <= link_local.size()) {
      return label;
    }

    const auto suffix = label.substr(label.size() - link_local.size());
    const bool matches = std::ranges::equal(suffix, link_local, [](char left, char right) {
      return (left >= 'A' && left <= 'Z' ? static_cast<char>(left - 'A' + 'a') : left) == right;
    });

    return matches ? label.substr(0, label.size() - link_local.size()) : label;
  }

  float MachineChromeGeometry::listRowHeight(const ChromeMetrics& chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + std::round(chrome.textPx(2 * list_vertical_padding));
  }

  float MachineChromeGeometry::listHeight(const ChromeMetrics& chrome, std::size_t rows) noexcept {
    return listRowHeight(chrome) * static_cast<float>(rows);
  }

  float MachineChromeGeometry::listNaturalWidth(const ChromeMetrics& chrome, float text_advance, bool stacked, bool marked) noexcept {
    return chrome.textPx((2 * list_padding) + list_avatar + list_gap) + (stacked ? chrome.textPx(list_gap + stack_width) : 0) + (marked ? chrome.textPx(list_gap + list_mark) : 0) + text_advance;
  }

  MachineChromeGeometry::ListColumns MachineChromeGeometry::listColumns(const ChromeMetrics& chrome) noexcept {
    const auto padding = std::round(chrome.textPx(list_padding));
    const auto avatar = std::round(chrome.textPx(list_avatar));
    const auto gap = std::round(chrome.textPx(list_gap));

    return {.mark_center = padding + (avatar / 2), .text_x = padding + avatar + gap};
  }

  MachineChromeGeometry::ListRow MachineChromeGeometry::listRow(Rect area, const ChromeMetrics& chrome, std::size_t index, bool stacked, bool marked, bool described) noexcept {
    const auto height = listRowHeight(chrome);
    const auto padding = std::round(chrome.textPx(list_padding));
    const auto avatar = std::round(chrome.textPx(list_avatar));
    const auto dot = std::round(chrome.textPx(list_dot));
    const auto gap = std::round(chrome.textPx(list_gap));
    const auto label_height = ChromeMetrics::lineHeight(chrome.body);
    ListRow row;

    row.bounds = {.x = area.x, .y = area.y + (height * static_cast<float>(index)), .width = area.width, .height = height};
    row.avatar = {.x = area.x + padding, .y = row.bounds.y + std::round((height - avatar) / 2), .width = avatar, .height = avatar};

    const auto overhang = std::round(chrome.textPx(list_dot_overhang));

    row.dot = {.x = row.avatar.right() - dot + overhang, .y = row.avatar.bottom() - dot + overhang, .width = dot, .height = dot};

    // The columns at the end, from the edge in: the current mark, then the stack.
    auto end = area.right() - padding;

    if (marked) {
      const auto side = std::round(chrome.textPx(list_mark));

      row.mark = {.x = end - side, .y = row.bounds.y + std::round((height - side) / 2), .width = side, .height = side};
      end = row.mark.x - gap;
    }

    if (stacked) {
      const auto width = std::round(chrome.textPx(stack_width));

      row.stack = {.x = end - width, .y = row.bounds.y, .width = width, .height = height};
      end = row.stack.x - gap;
    }

    const auto left = area.x + listColumns(chrome).text_x;
    const auto width = std::max(0.0F, end - left);

    if (!described) {
      row.label = {.x = left, .y = row.bounds.y + std::round((height - label_height) / 2), .width = width, .height = label_height};
      return row;
    }

    const auto top = row.bounds.y + std::round(chrome.textPx(list_vertical_padding));

    row.label = {.x = left, .y = top, .width = width, .height = label_height};
    row.status = {.x = left, .y = top + label_height, .width = width, .height = ChromeMetrics::lineHeight(chrome.small)};

    return row;
  }

  float MachineChromeGeometry::preferredSegment(const ChromeMetrics& chrome, float advance) noexcept {
    return std::min(advance + chrome.px(segment_disc + segment_gap + (2 * segment_padding)), chrome.px(maximum_segment));
  }

  MachineChromeGeometry::Control MachineChromeGeometry::control(Rect area, const ChromeMetrics& chrome, Kind kind, float advance, bool attention) noexcept {
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

}
