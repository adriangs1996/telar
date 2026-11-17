module telar.gui.presentation.suggestion_labels;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.model;
import telar.gui.suggestions.state;

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

  PeekGeometry PeekGeometry::measure(CellRectangle host) noexcept {
    const auto modal = NamePromptGeometry::measure(host, requested_size);
    PeekGeometry result;

    result.bounds = modal.bounds;
    result.title = modal.title;
    const auto content = result.bounds.width > 2 && result.bounds.height > 2 ? result.bounds.inner(1) : result.bounds;
    if (content.height < chrome_rows) {
      return result;
    }

    result.facts = content.row(0);
    result.screen = content.row(1);
    result.screen.height = content.height - chrome_rows;
    result.field = content.row(content.height - field_rows_from_end);
    result.footer = content.row(content.height - 1);

    return result;
  }

  std::string_view SuggestionLabels::heading(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Start with a task";
    case SuggestionPhase::waiting:
      return "Generating a command…";
    case SuggestionPhase::ready:
      return "Suggested command";
    case SuggestionPhase::failed:
      return "Could not generate a command";
    }

    return {};
  }

  std::string_view SuggestionLabels::message(SuggestionPhase phase, SuggestionStatus status) noexcept {
    if (phase == SuggestionPhase::idle) {
      return "Describe the command you need, then press Enter.";
    }

    if (phase == SuggestionPhase::waiting) {
      return "Keep editing or press Esc to cancel.";
    }

    if (phase == SuggestionPhase::ready) {
      return {};
    }

    switch (status) {
    case SuggestionStatus::ready:
      return "The engine returned no command. Try again.";
    case SuggestionStatus::unavailable:
      return "Configure runtime.engine to enable suggestions.";
    case SuggestionStatus::timeout:
      return "The engine timed out. Try again.";
    case SuggestionStatus::failed:
      return "The engine could not answer. Try again.";
    }

    return {};
  }

  std::string_view SuggestionLabels::button(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Generate  ↵";
    case SuggestionPhase::waiting:
      return "Generating…";
    case SuggestionPhase::ready:
      return "Paste command  ↵";
    case SuggestionPhase::failed:
      return "Try again  ↵";
    }

    return {};
  }

  std::string_view SuggestionLabels::footer(SuggestionPhase phase) noexcept {
    return phase == SuggestionPhase::ready ? "Paste first, then run in shell." : "Review before pasting.";
  }

  bool SuggestionLabels::canSubmit(SuggestionPhase phase, std::string_view query) noexcept {
    return phase != SuggestionPhase::waiting && (phase == SuggestionPhase::ready || !query.empty());
  }

}
