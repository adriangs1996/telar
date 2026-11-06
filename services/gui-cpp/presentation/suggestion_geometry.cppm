module;

#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"


#include <span>
#include <stdexcept>

export module telar.gui.presentation.suggestion_geometry;

export import telar.gui.core.metrics;


export import telar.gui.machines.discovery;

// Interface: presentation/link_status_geometry.cppm
export {
namespace telar::gui {

struct LinkStatusGeometry {
  static constexpr float dim_alpha = 0.6F;
  static constexpr float line_height_factor = 1.5F;
  static constexpr float line_gap = 6;
  static constexpr float inset = 24;

  Rect bounds;
  Rect headline;
  Rect detail;

  [[nodiscard]] inline static LinkStatusGeometry measure(Rect area, const ChromeMetrics &chrome, bool has_detail) noexcept {
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
};

}
}

// Interface: presentation/machine_chrome_geometry.cppm
export {
namespace telar::gui {

struct MachineChromeGeometry {
  static constexpr float switcher_disc = 7;
  static constexpr float switcher_padding = 8;
  static constexpr float switcher_gap = 4;
  static constexpr float maximum_control = 120;
  static constexpr float segment_disc = 8;
  static constexpr float segment_padding = 10;
  static constexpr float segment_gap = 6;
  static constexpr float maximum_segment = 200;
  static constexpr float attention_diameter = 6;
  static constexpr float attention_gap = 6;

  enum class Kind : std::uint8_t {
    switcher,
    segment,
    fold,
  };

  struct Row {
    std::array<Rect, MachineLimits::window_slots> controls{};
    std::size_t count = 0;
    std::size_t hidden = 0;
    Rect fold;
  };

  struct Control {
    Rect bounds;
    Rect label;
    Rect disc;
    Rect attention;
    float radius = 0;
  };

  [[nodiscard]] inline static Row switcher(Rect area, const ChromeMetrics &chrome, std::span<const float> advances, float more_advance) {
    if (advances.size() > MachineLimits::window_slots) {
      throw std::length_error{"TooManyMachineControls"};
    }

    Row row;
    if (advances.size() <= 1 || area.empty()) {
      return row;
    }

    const auto more_reserve = more_advance + chrome.px(2 * switcher_padding);
    auto left = area.x;
    for (const auto advance : advances) {
      const auto width = switcherControlWidth(chrome, advance);
      if (row.hidden != 0 || left + width > area.right() - more_reserve) {
        ++row.hidden;
        continue;
      }

      row.controls[row.count++] = {.x = left, .y = area.y, .width = width, .height = area.height};
      left += width + chrome.px(switcher_gap);
    }

    if (row.hidden != 0) {
      row.fold = {.x = left, .y = area.y, .width = std::max(0.0F, std::min(more_reserve, area.right() - left)), .height = area.height};
    }

    return row;
  }

  [[nodiscard]] inline static float switcherControlWidth(const ChromeMetrics &chrome, float advance) noexcept {
    return std::min(advance + chrome.px((2 * switcher_padding) + switcher_disc + switcher_gap), chrome.px(maximum_control));
  }

  [[nodiscard]] inline static float preferredSwitcher(const ChromeMetrics &chrome, std::span<const float> advances, float more_advance) {
    if (advances.size() > MachineLimits::window_slots) {
      throw std::length_error{"TooManyMachineControls"};
    }

    if (advances.size() <= 1) {
      return 0;
    }

    float width = more_advance + chrome.px(2 * switcher_padding);
    for (const auto advance : advances) {
      width += switcherControlWidth(chrome, advance) + chrome.px(switcher_gap);
    }

    return width - chrome.px(switcher_gap);
  }

  [[nodiscard]] inline static float preferredSegment(const ChromeMetrics &chrome, float advance) noexcept {
    return std::min(advance + chrome.px(segment_disc + segment_gap + (2 * segment_padding)), chrome.px(maximum_segment));
  }

  [[nodiscard]] inline static Control control(Rect area, const ChromeMetrics &chrome, Kind kind, float advance, bool attention) noexcept {
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
};

}
}

// Interface: presentation/palette_geometry.cppm
export {
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

  [[nodiscard]] inline static PaletteGeometry measure(Rect viewport, const ChromeMetrics &chrome, Options options) noexcept {
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

  [[nodiscard]] inline static Rect inset(Rect bounds, float amount) noexcept {
    const auto x = std::min(amount, bounds.width / 2);
    const auto y = std::min(amount, bounds.height / 2);

    return {.x = bounds.x + x, .y = bounds.y + y, .width = std::max(0.0F, bounds.width - (x * 2)), .height = std::max(0.0F, bounds.height - (y * 2))};
  }

private:
  inline static Rect takeTop(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect result{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};
    remaining.y += taken;
    remaining.height -= taken;

    return result;
  }
};

}
}

// Interface: presentation/palette_row_window.cppm
export {
namespace telar::gui {

enum class PaletteRowKind : std::uint8_t {
  context,
  tab,
  agent,
  action,
  machine,
  pick,
};

struct PaletteRowWindow {
  static constexpr std::size_t capacity = 16;
  static constexpr float content_inset = 8;

  struct Row {
    std::size_t index = 0;
    Rect group;
    Rect bounds;
  };

  std::array<Row, capacity> rows{};
  std::size_t count = 0;
  std::size_t first = 0;

  [[nodiscard]] inline static PaletteRowWindow measure(std::span<const PaletteRowKind> kinds, std::size_t selection, const PaletteGeometry &geometry, const ChromeMetrics &chrome, bool grouped) noexcept {
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

private:
  [[nodiscard]] inline static float rowHeight(PaletteRowKind kind, const PaletteGeometry &geometry) noexcept {
    return kind == PaletteRowKind::agent ? geometry.agent_height : geometry.row_height;
  }
};

}
}

// Interface: presentation/sidebar_geometry.cppm
export {
namespace telar::gui {

struct SidebarGeometry {
  static constexpr float margin = 8;
  static constexpr float workspace_vertical_padding = 20;

  Rect machines;
  Rect projects_header;
  Rect projects;
  Rect activity_header;
  Rect activity;

  [[nodiscard]] inline static float workspaceHeight(const ChromeMetrics &chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(workspace_vertical_padding);
  }

  [[nodiscard]] inline static SidebarGeometry measure(Rect area, const ChromeMetrics &chrome, std::size_t, bool machines_shown = false) noexcept {
    const auto inset = chrome.px(margin);
    Rect content{.x = area.x + inset, .y = area.y + inset, .width = std::max(0.0F, area.width - 2 * inset), .height = std::max(0.0F, area.height - 2 * inset)};
    const auto header = chrome.pane_header;
    const auto gap = 0.0F;
    SidebarGeometry geometry;
    if (content.width <= 0 || content.height < header) {
      return geometry;
    }

    constexpr float minimum_machine_headers = 3;
    if (machines_shown && content.height >= minimum_machine_headers * header) {
      geometry.machines = {.x = content.x, .y = content.y, .width = content.width, .height = header};
      content.y += header + gap;
      content.height -= header + gap;
    }

    geometry.activity_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
    geometry.activity = {.x = content.x, .y = content.y + header + gap, .width = content.width, .height = std::max(0.0F, content.height - header - gap)};

    return geometry;
  }
};

}
}

// Interface: presentation/suggestion_geometry.cppm
export {
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

  [[nodiscard]] inline static SuggestionGeometry measure(const PaletteGeometry &palette, const ChromeMetrics &chrome, bool has_parent) noexcept {
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
}

// Interface: presentation/theme.cppm
export {
namespace telar::gui {

inline Color themeRgb(ThemeRgb bytes) noexcept {
  constexpr unsigned channel_bits = 8;

  return Color::rgb((static_cast<unsigned>(bytes[0]) << (channel_bits * 2)) | (static_cast<unsigned>(bytes[1]) << channel_bits) | bytes[2]);
}

inline Theme projectTheme(const ThemeValues &values) noexcept {
  Theme result;
  result.foreground = themeRgb(values.terminal.foreground);
  result.background = themeRgb(values.terminal.background);
  std::ranges::transform(values.terminal.palette, result.palette.begin(), themeRgb);
  result.cursor = values.terminal.cursor_color ? themeRgb(*values.terminal.cursor_color) : result.foreground;
  result.cursor_text = values.terminal.cursor_text_color ? std::optional{themeRgb(*values.terminal.cursor_text_color)} : std::nullopt;
  result.chrome = values.palette;
  result.surface = result.resolve(values.color(PaletteRole::surface0), result.background);
  result.elevated = result.resolve(values.color(PaletteRole::surface1), result.background);
  result.border = result.resolve(values.color(PaletteRole::overlay0), result.foreground);
  result.muted = result.resolve(values.color(PaletteRole::subtext0), result.foreground);
  result.accent = result.resolve(values.color(PaletteRole::accent), result.foreground);
  result.selection = result.elevated;
  result.success = result.resolve(values.color(PaletteRole::green), result.foreground);
  result.warning = result.resolve(values.color(PaletteRole::yellow), result.foreground);
  result.failure = result.resolve(values.color(PaletteRole::red), result.foreground);

  return result;
}

}
}
