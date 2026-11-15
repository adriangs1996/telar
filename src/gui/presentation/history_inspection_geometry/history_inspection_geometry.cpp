module telar.gui.presentation.history_inspection_geometry;

import std;

namespace telar::gui {

  AgentCardGeometry AgentCardGeometry::derive(const ChromeMetrics& chrome) noexcept {
    return {.small_row = ChromeMetrics::lineHeight(chrome.small), .title_row = ChromeMetrics::lineHeight(chrome.title), .scale = chrome.text_ratio};
  }

  float AgentCardGeometry::px(float logical) const noexcept {
    return std::round(logical * scale);
  }

  float AgentCardGeometry::textInset() const noexcept {
    return px(horizontal_padding) + px(mark_column) + px(gap);
  }

  float AgentCardGeometry::height() const noexcept {
    return (2 * small_row) + title_row + px(total_row_spacing) + (2 * px(vertical_padding));
  }

  float AgentCardGeometry::agentHeight() const noexcept {
    return title_row + small_row + px(title_gap) + (2 * px(vertical_padding));
  }

  float AgentCardGeometry::compactHeight() const noexcept {
    return title_row + (2 * px(compact_vertical_padding));
  }

  float AgentCardGeometry::cardWidth(float list_width) const noexcept {
    return std::max(0.0F, list_width - (scrollbar_width * scale) - px(spacing));
  }

  float AgentCardGeometry::listWidth(float card_width) const noexcept {
    return card_width + (scrollbar_width * scale) + px(spacing);
  }

  Rect AgentCardGeometry::row(Rect bounds, Row role) const noexcept {
    float top = 0;

    if (role == Row::title) {
      top = small_row + px(title_gap);
    } else if (role == Row::detail) {
      top = small_row + title_row + px(total_row_spacing);
    }

    return {.x = bounds.x + px(horizontal_padding), .y = bounds.y + px(vertical_padding) + top, .width = std::max(0.0F, bounds.width - (2 * px(horizontal_padding))), .height = role == Row::title ? title_row : small_row};
  }

  HistoryModalGeometry HistoryModalGeometry::measure(const HistoryModalMetrics& metrics, bool inspecting) noexcept {
    const auto& chrome = metrics.chrome;
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

  void HistoryModalGeometry::offsetY(float offset) noexcept {
    for (auto* area : {&bounds, &header, &results, &inspection, &search, &footer}) {
      area->y += offset;
    }
  }

  Rect HistoryModalGeometry::inspectionContent(const ChromeMetrics& chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto actions = inspectionActions(chrome);

    return {.x = inspection.x + inset, .y = inspection.y + inset, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = std::max(0.0F, actions.y - inspection.y - (inset * 2))};
  }

  Rect HistoryModalGeometry::inspectionActions(const ChromeMetrics& chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto height = std::min(std::max(chrome.px(action_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(action_padding)), std::max(0.0F, inspection.height - (inset * 2)));

    return {.x = inspection.x + inset, .y = inspection.y + inspection.height - inset - height, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = height};
  }

  float HistoryModalGeometry::inspectionInset(const ChromeMetrics& chrome) const noexcept {
    return std::min(chrome.px(inspection_inset), std::min(inspection.width, inspection.height) / inspection_inset_divisor);
  }

  Rect HistoryModalGeometry::takeBottom(Rect& remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);

    remaining.height -= taken;

    return {.x = remaining.x, .y = remaining.y + remaining.height, .width = remaining.width, .height = taken};
  }

  Rect HistoryModalGeometry::takeTop(Rect& remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect top{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};

    remaining.y += taken;
    remaining.height -= taken;

    return top;
  }

  HistoryInspectionGeometry HistoryInspectionGeometry::derive(Rect area, ChromeMetrics chrome, Point cell) noexcept {
    HistoryModalGeometry modal{};

    modal.inspection = area;
    const auto content = modal.inspectionContent(chrome);
    const auto bounded = [](float value) {
      return static_cast<std::uint16_t>(std::clamp(std::floor(value), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    };

    return {.content = content, .actions = modal.inspectionActions(chrome), .columns = bounded(content.width / std::max(1.0F, cell.x)), .rows = cell.y > 0 ? bounded(content.height / cell.y) : std::uint16_t{0}, .row_height = cell.y, .label_width = std::min(chrome.px(fact_label_width), content.width / fact_label_divisor), .command_inset = chrome.px(command_padding)};
  }

  Rect HistoryInspectionGeometry::row(std::size_t index) const noexcept {
    return {.x = content.x, .y = content.y + (static_cast<float>(index) * row_height), .width = content.width, .height = row_height};
  }

  Rect HistoryInspectionGeometry::text(Rect row, HistoryInspectionLine::Kind kind) const noexcept {
    if (kind == HistoryInspectionLine::Kind::command) {
      return {.x = row.x + command_inset, .y = row.y, .width = std::max(0.0F, row.width - (command_inset * 2)), .height = row.height};
    }

    if (kind == HistoryInspectionLine::Kind::fact) {
      return {.x = row.x + label_width, .y = row.y, .width = std::max(0.0F, row.width - label_width), .height = row.height};
    }

    return row;
  }

  auto HistoryInspectionGeometry::buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept -> std::array<Rect, maximum_actions> {
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

  PaneDecorationGeometry PaneDecorationGeometry::derive(const PaneLayout::Placement& placement, const WorkbenchGeometry& workbench) noexcept {
    const auto outer = workbench.pixels(placement.bounds);
    const auto content = workbench.pixels(placement.content);
    auto frame = outer;
    const auto& grid = workbench.grid;
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

  PaneAttentionGeometry PaneAttentionGeometry::derive(Rect physical_frame, float physical_ratio, float logical_radius) noexcept {
    return {
        .bounds = physical_frame.inset(inset_pixels, inset_pixels),
        .width = line_width * physical_ratio,
        .radius = std::max(0.0F, (logical_radius * physical_ratio) - inset_pixels),
    };
  }

}
