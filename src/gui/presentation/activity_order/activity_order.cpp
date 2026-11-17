module telar.gui.presentation.activity_order;

import std;

import telar.gui.foundation.agents;
import telar.gui.foundation.core;

namespace telar::gui {

  auto PaneStatusChip::text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds) -> Text {
    Text result;

    switch (status) {
    case AgentStatus::blocked:
      switch (reason) {
      case AgentBlockedReason::permission:
        result.append("permission");
        break;
      case AgentBlockedReason::question:
        result.append("question");
        break;
      case AgentBlockedReason::plan:
        result.append("plan");
        break;
      default:
        result.append("blocked");
        break;
      }

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
    default:
      return PaletteRole::teal;
    }
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
    const auto index_room = measurements.needs_attention ? std::max(0.0F, band.width - measurements.chip - part_gap * ratio) : band.width;
    const auto index_width = std::min(measurements.index, index_room);

    result.index = {.x = band.x, .y = band.y, .width = index_width, .height = band.height};
    auto x = band.x + index_width + (index_width > 0 ? part_gap * ratio : 0);
    const auto chip_width = measurements.chip <= end - x ? measurements.chip : 0;
    const auto text_end = end - (chip_width != 0 ? chip_width + (chip_gap * ratio) : 0);
    const auto paused_width = measurements.paused > 0 ? measurements.paused + (chip_gap * ratio) : 0;
    const bool paused_fits = paused_width != 0 && paused_width <= text_end - x;
    const auto name_width = std::max(0.0F, text_end - x - (paused_fits ? paused_width : 0));

    result.name = {.x = x, .y = band.y, .width = name_width, .height = band.height};
    x += std::min(name_width, measurements.name);
    if (paused_fits) {
      x += chip_gap * ratio;
      result.paused = {.x = x, .y = band.y, .width = std::max(0.0F, text_end - x), .height = band.height};
    }

    if (chip_width != 0) {
      result.chip = {.x = end - chip_width, .y = band.y, .width = chip_width, .height = band.height};
    }

    return result;
  }

}
