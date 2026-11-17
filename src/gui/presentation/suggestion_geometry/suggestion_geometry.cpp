module telar.gui.presentation.suggestion_geometry;

import std;

import telar.gui.foundation.core;

namespace telar::gui {

  LinkStatusGeometry LinkStatusGeometry::measure(Rect area, const ChromeMetrics& chrome, bool has_detail) noexcept {
    if (area.width <= 0 || area.height <= 0) {
      return {};
    }

    const auto height = static_cast<float>(chrome.title) * line_height_factor;
    const auto lines = has_detail ? 2.0F : 1.0F;
    const auto gap = chrome.px(line_gap);
    const auto block_height = (lines * height) + ((lines - 1) * gap);
    const Rect headline{.x = area.x + chrome.px(inset), .y = area.y + std::max(0.0F, (area.height - block_height) / 2), .width = std::max(0.0F, area.width - 2 * chrome.px(inset)), .height = height};
    auto detail = headline;

    detail.y += height + gap;

    return {.bounds = area, .headline = headline, .detail = detail};
  }

  std::string_view MachineChromeGeometry::listStatus(bool live, std::size_t agents, std::span<char, list_status_capacity> storage) noexcept {
    if (!live) {
      return "Offline";
    }

    if (agents == 0) {
      return "No active agents";
    }

    if (agents == 1) {
      return "1 active agent";
    }

    constexpr std::string_view suffix = " active agents";
    auto* const last = storage.data() + storage.size();
    const auto [end, error] = std::to_chars(storage.data(), last, agents);
    if (error != std::errc{} || static_cast<std::size_t>(last - end) < suffix.size()) {
      return suffix.substr(1);
    }

    std::ranges::copy(suffix, end);

    return {storage.data(), static_cast<std::size_t>(end - storage.data()) + suffix.size()};
  }

  float MachineChromeGeometry::listRowHeight(const ChromeMetrics& chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + std::round(chrome.textPx(2 * list_vertical_padding));
  }

  float MachineChromeGeometry::listHeight(const ChromeMetrics& chrome, std::size_t rows) noexcept {
    return listRowHeight(chrome) * static_cast<float>(rows);
  }

  float MachineChromeGeometry::listNaturalWidth(const ChromeMetrics& chrome, float text_advance, bool stacked) noexcept {
    return chrome.textPx((2 * list_padding) + list_avatar + list_gap) + (stacked ? chrome.textPx(list_gap + stack_width) : 0) + text_advance;
  }

  MachineChromeGeometry::ListRow MachineChromeGeometry::listRow(Rect area, const ChromeMetrics& chrome, std::size_t index, bool stacked) noexcept {
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
    if (stacked) {
      const auto width = std::round(chrome.textPx(stack_width));

      row.stack = {.x = area.right() - padding - width, .y = row.bounds.y, .width = width, .height = height};
    }

    const auto left = row.avatar.right() + gap;
    const auto right = stacked ? row.stack.x - gap : area.right() - padding;
    const auto top = row.bounds.y + std::round(chrome.textPx(list_vertical_padding));
    const auto width = std::max(0.0F, right - left);

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
