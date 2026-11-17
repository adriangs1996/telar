module telar.gui.features.history;

import std;

import telar.gui.foundation.core;

namespace telar::gui::features::history {

  HistoryCommandLine HistoryCommandLine::derive(Rect bounds, HistoryCommandMetrics metrics) noexcept {
    HistoryCommandLine result;

    result.text = bounds;
    const auto cell = std::max(1.0F, metrics.cell_width);
    const auto columns = std::floor(bounds.width / cell);
    const auto overflows = metrics.needed > bounds.width;
    if ((overflows || metrics.continues) && columns >= minimum_marked_columns) {
      const auto tail_limit = (columns - 1) * cell;

      result.text.width = overflows ? tail_limit : std::min(metrics.needed + cell, tail_limit);
      result.marker = {.x = bounds.x + result.text.width, .y = bounds.y, .width = cell, .height = bounds.height};
      result.mark = overflows ? ellipsis : continuation;
    }

    return result;
  }

  Rect HistoryLoading::line(Rect area, ChromeMetrics chrome, std::optional<std::uint64_t> now_ns) noexcept {
    const auto step = now_ns ? (*now_ns / step_ns) % steps : steps / 3;
    const auto span = area.width / span_divisor;
    const auto travel = area.width + span;
    const auto x = area.x - span + (travel * static_cast<float>(step) / static_cast<float>(steps));

    return {.x = x, .y = area.y, .width = span, .height = chrome.px(thickness)};
  }

  HistoryExpansion HistorySelectionMotion::sample(std::optional<std::uint64_t> generation, std::optional<HistoryPosition> selected, std::optional<std::uint64_t> timestamp) noexcept {
    if (!generation || !selected) {
      *this = {};

      return {};
    }

    if (!timestamp || generation_ != generation) {
      *this = {};
      generation_ = generation;
      selected_ = *selected;

      return {};
    }

    if (selected_.index != selected->index) {
      leaving_from_ = eased(value(*timestamp));
      leaving_ = selected_;
      selected_ = *selected;
      started_ns_ = *timestamp;
      transitioning_ = true;
    } else if (selected_.id != selected->id) {
      selected_ = *selected;
      leaving_.reset();
      transitioning_ = false;
    }

    const auto open = eased(value(*timestamp));
    if (open >= 1) {
      leaving_.reset();
    }

    return {.open = open, .leaving = leaving_, .leaving_open = leaving_from_ * (1 - open)};
  }

  std::optional<std::uint64_t> HistorySelectionMotion::deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!transitioning_) {
      return {};
    }

    if (now_ns < started_ns_) {
      return started_ns_;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return {};
    }

    return std::min(add(now_ns, interval_ns), add(started_ns_, duration_ns));
  }

  std::uint64_t HistorySelectionMotion::add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

  float HistorySelectionMotion::eased(float progress) noexcept {
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  float HistorySelectionMotion::value(std::uint64_t now_ns) const noexcept {
    if (!transitioning_) {
      return 1;
    }

    if (now_ns < started_ns_) {
      return 0;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return 1;
    }

    return static_cast<float>(now_ns - started_ns_) / static_cast<float>(duration_ns);
  }

}
