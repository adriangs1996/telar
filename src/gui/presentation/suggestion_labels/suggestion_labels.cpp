module telar.gui.presentation.suggestion_labels;

import std;
import telar.gui.presentation.activity_order;
import telar.wire.vocabulary;
import telar.gui.model.records;

namespace telar::gui {

  float AgentAnimation::alpha(std::uint64_t now_ns) noexcept {
    return AgentStatusPresentation::pulse(static_cast<std::uint8_t>(now_ns / pulse_interval_ns));
  }

  std::optional<std::uint64_t> AgentAnimation::deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept {
    if (!connected || (status != AgentStatus::working && status != AgentStatus::ready)) {
      return std::nullopt;
    }

    const auto interval = status == AgentStatus::working ? pulse_interval_ns : StatusAgeInterval::nanoseconds_per_second;
    const auto remaining = interval - (now_ns % interval);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }

  NamePromptGeometry NamePromptGeometry::measure(CellRectangle host, CellRectangle wanted) noexcept {
    const auto margin_x = host.width > horizontal_threshold ? horizontal_margin : 0;
    const auto margin_y = host.height > vertical_threshold ? vertical_margin : 0;
    const auto width = std::min(wanted.width, static_cast<std::uint16_t>(host.width - (margin_x * 2)));
    const auto height = std::min(wanted.height, static_cast<std::uint16_t>(host.height - (margin_y * 2)));
    NamePromptGeometry result;

    result.bounds = {.x = coordinate(static_cast<std::uint32_t>(host.x) + ((host.width - width) / 2)), .y = coordinate(static_cast<std::uint32_t>(host.y) + ((host.height - height) / 2)), .width = width, .height = height};
    const auto content = width > 2 && height > 2 ? result.bounds.inner(1) : result.bounds;

    if (width > 4) {
      result.title = {.x = coordinate(static_cast<std::uint32_t>(result.bounds.x) + 2), .y = result.bounds.y, .width = static_cast<std::uint16_t>(width - 4), .height = 1};
    }

    result.field = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + (content.height > 2 ? 1 : 0)), .width = content.width, .height = std::min<std::uint16_t>(1, content.height)};
    if (content.height > 2) {
      result.footer = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + content.height - 1), .width = content.width, .height = 1};
    }

    return result;
  }

  std::uint16_t NamePromptGeometry::coordinate(std::uint32_t value) noexcept {
    return static_cast<std::uint16_t>(std::min<std::uint32_t>(value, std::numeric_limits<std::uint16_t>::max()));
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

  float ModalMotion::sample(std::optional<std::uint64_t> generation, std::optional<std::uint64_t> timestamp) noexcept {
    if (!generation) {
      *this = {};

      return 1;
    }

    if (!timestamp) {
      *this = {};
      generation_ = generation;

      return 1;
    }

    if (generation_ != generation) {
      generation_ = generation;
      started_ns_ = timestamp;
    }

    if (!started_ns_) {
      return 1;
    }

    if (*timestamp < *started_ns_) {
      return 0;
    }

    if (*timestamp - *started_ns_ >= duration_ns) {
      return 1;
    }

    const auto progress = static_cast<float>(*timestamp - *started_ns_) / static_cast<float>(duration_ns);
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  std::optional<std::uint64_t> ModalMotion::deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!started_ns_ || (now_ns >= *started_ns_ && now_ns - *started_ns_ >= duration_ns)) {
      return {};
    }

    if (now_ns < *started_ns_) {
      return started_ns_;
    }

    return std::min(add(now_ns, interval_ns), add(*started_ns_, duration_ns));
  }

  std::uint64_t ModalMotion::add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
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
