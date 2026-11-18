module telar.gui.features.activity;

import std;
import telar.wire.vocabulary;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::activity {

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

  float AgentAnimation::alpha(std::uint64_t now_ns) noexcept {
    return AgentStatusPresentation::pulse(static_cast<std::uint8_t>(now_ns / pulse_interval_ns));
  }

  ds::Option<std::uint64_t> AgentAnimation::deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept {
    if (!connected || status == AgentStatus::unknown) {
      return ds::none;
    }

    const auto interval = status == AgentStatus::working ? pulse_interval_ns : StatusAgeInterval::nanoseconds_per_second;
    const auto remaining = interval - (now_ns % interval);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }

}
