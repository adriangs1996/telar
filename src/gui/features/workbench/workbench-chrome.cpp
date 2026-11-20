module telar.gui.features.workbench;

import std;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.model;

namespace telar::gui::features::workbench {

  namespace {

    // The chip's word for why an agent is blocked.
    std::string_view blockedWord(AgentBlockedReason reason) noexcept {
      switch (reason) {
      case AgentBlockedReason::permission:
        return "permission";
      case AgentBlockedReason::question:
        return "question";
      case AgentBlockedReason::plan:
        return "plan";
      case AgentBlockedReason::none:
      case AgentBlockedReason::other:
        break;
      }

      // A reason without a word of its own, or one outside the enum.
      return "blocked";
    }

  }

  auto PaneStatusChip::text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds) -> Text {
    Text result;

    switch (status) {
    case AgentStatus::blocked:
      result.append(blockedWord(reason));
      break;
    case AgentStatus::working:
      result.append("working ");
      if (seconds < AgentStatusPresentation::seconds_per_minute) {
        result.appendDecimal(seconds);
        result.append("s");
      } else if (seconds < AgentStatusPresentation::seconds_per_hour) {
        result.appendDecimal(seconds / AgentStatusPresentation::seconds_per_minute);
        result.append("m");
      } else {
        result.appendDecimal(seconds / AgentStatusPresentation::seconds_per_hour);
        result.append("h");
      }

      break;
    case AgentStatus::done:
      result.append("done");
      break;
    case AgentStatus::failed:
      result.append("failed");
      break;
    case AgentStatus::ready:
      result.append("ready");
      break;
    case AgentStatus::unknown:
      break;
    }

    return result;
  }

  PaletteRole PaneStatusChip::color(AgentStatus status) noexcept {
    return status == AgentStatus::ready ? PaletteRole::green : AgentStatusPresentation::color(status);
  }

  auto PaneProgressPresentation::text(PaneProgressState state, std::uint8_t percent) -> Text {
    Text result;

    switch (state) {
    case PaneProgressState::indeterminate:
      result.append("Working");
      break;
    case PaneProgressState::pause:
      result.append("Paused");
      break;
    case PaneProgressState::error:
      result.append("Error");
      break;
    case PaneProgressState::set:
      result.appendDecimal(percent);
      result.append("%");
      break;
    case PaneProgressState::remove:
      break;
    }

    return result;
  }

  PaletteRole PaneProgressPresentation::color(PaneProgressState state) noexcept {
    switch (state) {
    case PaneProgressState::error:
      return PaletteRole::red;
    case PaneProgressState::pause:
      return PaletteRole::yellow;
    case PaneProgressState::remove:
    case PaneProgressState::set:
    case PaneProgressState::indeterminate:
      break;
    }

    // Progress that is going well, or a state outside the enum.
    return PaletteRole::teal;
  }

  PaneHeaderGeometry PaneHeaderGeometry::derive(Rect row, const PaneHeaderMetrics& metrics, const PaneHeaderMeasurements& measurements) noexcept {
    PaneHeaderGeometry result;
    const auto ratio = metrics.ratio;
    const auto band_height = std::min(row.height, metrics.maximum_band_height);
    if (band_height <= 0 || row.width <= 0) {
      return result;
    }

    Rect band{.x = row.x + (margin * ratio), .y = row.y, .width = std::max(0.0F, row.width - (2 * margin * ratio)), .height = band_height};
    const auto reserved = measurements.index + measurements.chip + (minimum_text_room * ratio);
    auto progress_width = measurements.progress;
    if (progress_width > std::min(band.width / 2, std::max(0.0F, band.width - reserved))) {
      result.compact_progress = true;
      progress_width = measurements.compact_progress;
    }

    const auto attention_width = measurements.needs_attention ? measurements.chip : 0;
    if (progress_width > 0 && progress_width + measurements.index + attention_width + (minimum_text_room * ratio) <= band.width) {
      result.progress = {.x = band.x + band.width - progress_width, .y = band.y, .width = progress_width, .height = band.height};
      band.width = std::max(0.0F, band.width - progress_width - (part_gap * ratio));
    }

    const auto end = band.x + band.width;
    const auto index_room = measurements.needs_attention ? std::max(0.0F, band.width - measurements.chip - (part_gap * ratio)) : band.width;
    const auto index_width = std::min(measurements.index, index_room);

    result.index = {.x = band.x, .y = band.y, .width = index_width, .height = band.height};
    auto x = band.x + index_width + (index_width > 0 ? part_gap * ratio : 0);
    const auto chip_width = measurements.chip <= end - x ? measurements.chip : 0;
    const auto text_end = end - (std::not_equal_to<>{}(chip_width, 0.0F) ? chip_width + (chip_gap * ratio) : 0);
    const auto paused_width = measurements.paused > 0 ? measurements.paused + (chip_gap * ratio) : 0;
    const bool paused_fits = std::not_equal_to<>{}(paused_width, 0.0F) && paused_width <= text_end - x;
    const auto name_width = std::max(0.0F, text_end - x - (paused_fits ? paused_width : 0));

    result.name = {.x = x, .y = band.y, .width = name_width, .height = band.height};
    x += std::min(name_width, measurements.name);
    if (paused_fits) {
      x += chip_gap * ratio;
      result.paused = {.x = x, .y = band.y, .width = std::max(0.0F, text_end - x), .height = band.height};
    }

    if (std::not_equal_to<>{}(chip_width, 0.0F)) {
      result.chip = {.x = end - chip_width, .y = band.y, .width = chip_width, .height = band.height};
    }

    return result;
  }

  WorkspaceMark WorkspaceMark::resolve(std::string_view name) {
    WorkspaceMark mark;

    mark.hue = hues[hash(name) % hues.size()];
    if (name.empty()) {
      return mark;
    }

    const auto leading = std::countl_one(static_cast<std::uint8_t>(name.front()));
    const auto length = leading == 0 ? std::size_t{1} : static_cast<std::size_t>(leading);
    if (leading == 1 || length > mark.initial.bytes.size() || length > name.size()) {
      return mark;
    }

    try {
      const auto scalar = Utf8Scalar::decode(name.substr(0, length));
      const auto upper = scalar >= 'a' && scalar <= 'z' ? scalar - ('a' - 'A') : scalar;

      mark.initial = Utf8Scalar::encode(upper);
    } catch (const std::invalid_argument&) {
      return mark;
    }

    return mark;
  }

  std::uint32_t WorkspaceMark::hash(std::string_view name) noexcept {
    constexpr std::uint32_t offset_basis = 2166136261U;
    constexpr std::uint32_t prime = 16777619U;
    auto value = offset_basis;

    for (const auto byte : name) {
      value = (value ^ static_cast<unsigned char>(byte)) * prime;
    }

    return value;
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
