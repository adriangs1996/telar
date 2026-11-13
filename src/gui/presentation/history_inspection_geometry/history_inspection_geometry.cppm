module;
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cmath>
#include <cstdint>
#include <cstddef>


#include <cstring>
#include <ghostty/vt/unicode.h>


export module telar.gui.presentation.history_inspection_geometry;

import std;

export import telar.gui.core.metrics;


export import telar.gui.presentation.history_inspection;
export import telar.gui.presentation.history_filter_geometry;


export import telar.gui.application.sound_playback;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: presentation/chrome_style.cppm
export {
namespace telar::gui {

  // Logical radii and theme-relative state opacities shared by window chrome.
  struct ChromeStyle {
    static constexpr float small_radius = 4;
    static constexpr float control_radius = 6;
    static constexpr float surface_radius = 10;
    static constexpr float dialog_radius = 12;
    static constexpr float hover_alpha = 0.045F;
    static constexpr float selection_alpha = 0.09F;
    static constexpr float outline_alpha = 0.12F;
    static constexpr float focus_alpha = 0.65F;
  };

}
}

// Interface: presentation/agent_card_geometry.cppm
export {
namespace telar::gui {

struct AgentCardGeometry {
  static constexpr float horizontal_padding = 8;
  static constexpr float vertical_padding = 8;
  static constexpr float compact_vertical_padding = 4;
  static constexpr float task_indent = 12;
  static constexpr float spacing = 3;
  static constexpr float radius = ChromeStyle::surface_radius;
  static constexpr float gap = 6;
  static constexpr float mark_side = 14;
  static constexpr float tile_width = 18;
  static constexpr float tile_height = 14;
  static constexpr float project_label_gap = 4;
  static constexpr float project_label_minimum = 24;
  static constexpr float title_gap = 4;
  static constexpr float total_row_spacing = 6;
  static constexpr float group_gap = 8;
  static constexpr float scrollbar_width = 3;
  static constexpr float icon_size_ratio = 0.85F;
  static constexpr float provider_alpha = 0.6F;

  enum class Row : std::uint8_t {
    context,
    title,
    detail,
  };

  float small_row = 0;
  float title_row = 0;
  float scale = 1;

  [[nodiscard]] inline static AgentCardGeometry derive(const ChromeMetrics &chrome) noexcept {
    return {.small_row = ChromeMetrics::lineHeight(chrome.small), .title_row = ChromeMetrics::lineHeight(chrome.title), .scale = chrome.ratio};
  }

  [[nodiscard]] inline float px(float logical) const noexcept {
    return std::round(logical * scale);
  }

  [[nodiscard]] inline float height() const noexcept {
    return (2 * small_row) + title_row + px(total_row_spacing) + (2 * px(vertical_padding));
  }

  [[nodiscard]] inline float agentHeight() const noexcept {
    return title_row + small_row + px(title_gap) + (2 * px(vertical_padding));
  }

  [[nodiscard]] inline float compactHeight() const noexcept {
    return title_row + (2 * px(compact_vertical_padding));
  }

  [[nodiscard]] inline float cardWidth(float list_width) const noexcept {
    return std::max(0.0F, list_width - (scrollbar_width * scale) - px(spacing));
  }

  // The list width whose cards are `card_width` wide.
  [[nodiscard]] inline float listWidth(float card_width) const noexcept {
    return card_width + (scrollbar_width * scale) + px(spacing);
  }

  [[nodiscard]] inline Rect row(Rect bounds, Row role) const noexcept {
    float top = 0;
    if (role == Row::title) {
      top = small_row + px(title_gap);
    } else if (role == Row::detail) {
      top = small_row + title_row + px(total_row_spacing);
    }

    return {.x = bounds.x + px(horizontal_padding), .y = bounds.y + px(vertical_padding) + top, .width = std::max(0.0F, bounds.width - (2 * px(horizontal_padding))), .height = role == Row::title ? title_row : small_row};
  }
};

}
}

// Interface: presentation/form_button_style.cppm
export {
namespace telar::gui {

struct FormButtonStyle {
  static constexpr float radius = ChromeStyle::control_radius;
  static constexpr float disabled_alpha = 0.4F;
  static constexpr float pressed_alpha = 0.8F;
};

}
}

// Interface: presentation/history_modal_geometry.cppm
export {
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

  [[nodiscard]] inline static HistoryModalGeometry measure(const HistoryModalMetrics &metrics, bool inspecting) noexcept {
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

  inline void offsetY(float offset) noexcept {
    for (auto *area : {&bounds, &header, &results, &inspection, &search, &footer}) {
      area->y += offset;
    }
  }

  [[nodiscard]] inline Rect inspectionContent(const ChromeMetrics &chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto actions = inspectionActions(chrome);

    return {.x = inspection.x + inset, .y = inspection.y + inset, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = std::max(0.0F, actions.y - inspection.y - (inset * 2))};
  }

  [[nodiscard]] inline Rect inspectionActions(const ChromeMetrics &chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto height = std::min(std::max(chrome.px(action_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(action_padding)), std::max(0.0F, inspection.height - (inset * 2)));

    return {.x = inspection.x + inset, .y = inspection.y + inspection.height - inset - height, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = height};
  }

private:
  [[nodiscard]] inline float inspectionInset(const ChromeMetrics &chrome) const noexcept {
    return std::min(chrome.px(inspection_inset), std::min(inspection.width, inspection.height) / inspection_inset_divisor);
  }

  inline static Rect takeBottom(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    remaining.height -= taken;

    return {.x = remaining.x, .y = remaining.y + remaining.height, .width = remaining.width, .height = taken};
  }

  inline static Rect takeTop(Rect &remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect top{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};
    remaining.y += taken;
    remaining.height -= taken;

    return top;
  }
};

}
}

// Interface: presentation/history_inspection_geometry.cppm
export {
namespace telar::gui {

struct HistoryInspectionGeometry {
  static constexpr std::size_t maximum_actions = history_inspection_action_count;
  static constexpr float command_padding = 8;
  static constexpr float fact_label_width = 64;
  static constexpr float fact_label_divisor = 3;
  static constexpr float button_padding = 24;
  static constexpr float button_gap = 8;
  static constexpr float button_radius = FormButtonStyle::radius;
  static constexpr float disabled_alpha = FormButtonStyle::disabled_alpha;
  static constexpr float pressed_alpha = FormButtonStyle::pressed_alpha;

  Rect content;
  Rect actions;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  float row_height = 0;
  float label_width = 0;
  float command_inset = 0;

  [[nodiscard]] inline static HistoryInspectionGeometry derive(Rect area, ChromeMetrics chrome, Point cell) noexcept {
    HistoryModalGeometry modal{};
    modal.inspection = area;
    const auto content = modal.inspectionContent(chrome);
    const auto bounded = [](float value) {
      return static_cast<std::uint16_t>(std::clamp(std::floor(value), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    };

    return {.content = content, .actions = modal.inspectionActions(chrome), .columns = bounded(content.width / std::max(1.0F, cell.x)), .rows = cell.y > 0 ? bounded(content.height / cell.y) : std::uint16_t{0}, .row_height = cell.y, .label_width = std::min(chrome.px(fact_label_width), content.width / fact_label_divisor), .command_inset = chrome.px(command_padding)};
  }

  [[nodiscard]] inline Rect row(std::size_t index) const noexcept {
    return {.x = content.x, .y = content.y + (static_cast<float>(index) * row_height), .width = content.width, .height = row_height};
  }

  [[nodiscard]] inline Rect text(Rect row, HistoryInspectionLine::Kind kind) const noexcept {
    if (kind == HistoryInspectionLine::Kind::command) {
      return {.x = row.x + command_inset, .y = row.y, .width = std::max(0.0F, row.width - (command_inset * 2)), .height = row.height};
    }

    if (kind == HistoryInspectionLine::Kind::fact) {
      return {.x = row.x + label_width, .y = row.y, .width = std::max(0.0F, row.width - label_width), .height = row.height};
    }

    return row;
  }

  [[nodiscard]] inline std::array<Rect, maximum_actions> buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept {
    std::array<Rect, maximum_actions> result{};
    auto x = actions.x;
    for (std::size_t index = 0; index < std::min(advances.size(), result.size()); ++index) {
      const auto width = advances[index] + chrome.px(button_padding);
      if (x + width > actions.right()) {
        break;
      }

      result[index] = {.x = x, .y = actions.y, .width = width, .height = actions.height};
      x += width + chrome.px(button_gap);
    }

    return result;
  }
};

}
}

// Interface: presentation/pane_decoration_geometry.cppm
export {
namespace telar::gui {

struct PaneDecorationGeometry {
  static constexpr float frame_radius = ChromeStyle::dialog_radius;
  static constexpr float frame_line_width = 1;
  static constexpr float dim_alpha = 0.28F;
  static constexpr std::size_t panel_count = 6;

  Rect outer;
  Rect content;
  Rect frame;
  std::array<Rect, panel_count> panels;

  [[nodiscard]] inline static PaneDecorationGeometry derive(const PaneLayout::Placement &placement, const WorkbenchGeometry &workbench) noexcept {
    const auto outer = workbench.pixels(placement.bounds);
    const auto content = workbench.pixels(placement.content);
    auto frame = outer;
    const auto &grid = workbench.grid;
    const auto gap = workbench.layout_metrics.gap;
    const auto minimum_cell = std::min(grid.cell_width_px, grid.cell_height_px);
    const auto area = workbench.cellArea();
    if (placement.bounds.right() < area.right()) {
      frame.width += static_cast<float>(gap * (grid.cell_width_px - minimum_cell) / grid.scale);
    }

    if (placement.bounds.bottom() < area.bottom()) {
      frame.height += static_cast<float>(gap * (grid.cell_height_px - minimum_cell) / grid.scale);
    }

    // Frames on the workbench edge absorb the columns' rounding, so outer margins stay even.
    if (placement.framed && gap != 0) {
      if (placement.bounds.right() >= area.right()) {
        frame.width = std::max(frame.width, workbench.area.right() - frame.x);
      }

      if (placement.bounds.bottom() >= area.bottom()) {
        frame.height = std::max(frame.height, workbench.area.bottom() - frame.y);
      }
    }

    const auto right = content.right();
    const auto bottom = content.bottom();
    return {
        .outer = outer,
        .content = content,
        .frame = frame,
        .panels = {
            Rect{.x = outer.x, .y = outer.y, .width = outer.width, .height = std::max(0.0F, content.y - outer.y)},
            Rect{.x = outer.x, .y = bottom, .width = outer.width, .height = std::max(0.0F, outer.bottom() - bottom)},
            Rect{.x = outer.x, .y = content.y, .width = std::max(0.0F, content.x - outer.x), .height = content.height},
            Rect{.x = right, .y = content.y, .width = std::max(0.0F, outer.right() - right), .height = content.height},
            Rect{.x = outer.right(), .y = outer.y, .width = frame.width - outer.width, .height = outer.height},
            Rect{.x = outer.x, .y = outer.bottom(), .width = outer.width, .height = frame.height - outer.height},
        },
    };
  }
};

}
}

// Interface: presentation/pane_attention_geometry.cppm
export {
namespace telar::gui {

struct PaneAttentionGeometry {
  static constexpr float line_width = 2;
  static constexpr float inset_pixels = 1;

  Rect bounds;
  float width = 0;
  float radius = 0;

  [[nodiscard]] inline static PaneAttentionGeometry derive(Rect physical_frame, float physical_ratio, float logical_radius = PaneDecorationGeometry::frame_radius) noexcept {
    return {
        .bounds = physical_frame.inset(inset_pixels, inset_pixels),
        .width = line_width * physical_ratio,
        .radius = std::max(0.0F, (logical_radius * physical_ratio) - inset_pixels),
    };
  }
};

}
}
