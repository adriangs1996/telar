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

  PaletteGeometry PaletteGeometry::measure(Rect viewport, const ChromeMetrics& chrome, Options options) noexcept {
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
    std::optional<PaletteRowKind> previous;

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

      result.rows[result.count++] = {.index = index, .group = group, .bounds = {.x = bounds.x, .y = y, .width = bounds.width, .height = height}};
      y += height;
    }

    return result;
  }

  float PaletteRowWindow::rowHeight(PaletteRowKind kind, const PaletteGeometry& geometry) noexcept {
    return kind == PaletteRowKind::agent ? geometry.agent_height : geometry.row_height;
  }

  float SidebarGeometry::sectionGap(const ChromeMetrics& chrome) noexcept {
    return std::round(chrome.textPx(section_gap));
  }

  float SidebarGeometry::workspaceHeight(const ChromeMetrics& chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(workspace_vertical_padding);
  }

  SidebarGeometry SidebarGeometry::measure(Rect area, const ChromeMetrics& chrome, std::size_t, SidebarMachines machines) noexcept {
    const auto inset = std::round(chrome.textPx(margin));
    Rect content{.x = area.x + inset, .y = area.y + inset, .width = std::max(0.0F, area.width - 2 * inset), .height = std::max(0.0F, area.height - 2 * inset)};
    const auto header = chrome.pane_header;
    const auto gap = 0.0F;
    SidebarGeometry geometry;

    if (content.width <= 0 || content.height < header) {
      return geometry;
    }

    constexpr float minimum_machine_headers = 3;
    if (machines.shown && content.height >= minimum_machine_headers * header) {
      geometry.machines_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
      content.y += header;
      content.height -= header;
      // Activity keeps two headers of room; machine rows that do not fit stay out whole.
      const auto row = MachineChromeGeometry::listRowHeight(chrome);
      const auto section = sectionGap(chrome);
      const auto room = std::max(0.0F, content.height - ((minimum_machine_headers - 1) * header) - section);
      const auto rows = std::min(static_cast<float>(machines.rows), std::floor(room / row));

      geometry.machines = {.x = content.x, .y = content.y, .width = content.width, .height = rows * row};
      content.y += geometry.machines.height + section;
      content.height -= geometry.machines.height + section;
    }

    geometry.activity_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
    geometry.activity = {.x = content.x, .y = content.y + header + gap, .width = content.width, .height = std::max(0.0F, content.height - header - gap)};

    return geometry;
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

}
