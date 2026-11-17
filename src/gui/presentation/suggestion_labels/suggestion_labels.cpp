module telar.gui.presentation.suggestion_labels;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.model;

namespace telar::gui {

  float AgentAnimation::alpha(std::uint64_t now_ns) noexcept {
    return AgentStatusPresentation::pulse(static_cast<std::uint8_t>(now_ns / pulse_interval_ns));
  }

  std::optional<std::uint64_t> AgentAnimation::deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept {
    if (!connected || status == AgentStatus::unknown) {
      return std::nullopt;
    }

    const auto interval = status == AgentStatus::working ? pulse_interval_ns : StatusAgeInterval::nanoseconds_per_second;
    const auto remaining = interval - (now_ns % interval);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }

  AttachmentModalGeometry AttachmentModalGeometry::measure(CellRectangle host) noexcept {
    const CellRectangle wanted{
        .width = host.width > margin_columns ? static_cast<std::uint16_t>(host.width - margin_columns) : std::uint16_t{},
        .height = host.height > margin_rows ? static_cast<std::uint16_t>(host.height - margin_rows) : std::uint16_t{},
    };

    const auto modal = NamePromptGeometry::measure(host, wanted);
    AttachmentModalGeometry result{.bounds = modal.bounds, .title = modal.title};
    if (result.bounds.width > 4) {
      result.close = {.x = static_cast<std::uint16_t>(result.bounds.x + result.bounds.width - 3), .y = result.bounds.y, .width = 2, .height = 1};
    }

    const auto content = result.bounds.width > 2 && result.bounds.height > 2 ? result.bounds.inner(1) : result.bounds;
    if (content.height >= minimum_content_rows) {
      result.image = content;
      --result.image.height;
      result.footer = content.row(content.height - 1);
    }

    return result;
  }

}
