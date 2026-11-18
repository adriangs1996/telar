module telar.gui.features.terminal.graphics;

import std;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::graphics {

  template <typename Result>
  Result GraphicsPauses::PaneCall<Result>::operator()(std::uint64_t pane_id) const {
    return call(context, pane_id);
  }

  bool GraphicsPauses::contains(std::uint64_t pane_id) const noexcept {
    const auto slot = find(pane_id);

    return slot && !rows_[*slot].resumed_ns;
  }

  std::span<const GraphicsPauses::Row> GraphicsPauses::rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  std::uint64_t GraphicsPauses::revision() const noexcept {
    return revision_;
  }

  ds::Option<std::uint64_t> GraphicsPauses::nextDeadline() const noexcept {
    if (waiting_count_ == 0) {
      return ds::none;
    }

    auto earliest = std::numeric_limits<std::uint64_t>::max();

    for (const auto& row : rows()) {
      if (row.waiting) {
        earliest = std::min(earliest, row.due_ns);
      }
    }

    return earliest;
  }

  void GraphicsPauses::pause(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request, PaneCall<void> notice) {
    auto slot = find(pane_id);
    if (slot) {
      auto& row = rows_[*slot];
      if (row.resumed_ns) {
        const auto resumed = *row.resumed_ns;

        row.resumed_ns.reset();
        ++revision_;
        if (elapsed(now_ns, resumed) >= healthy_window_ns) {
          remove(*slot);
          slot.reset();
        }
      }
    }

    if (!slot) {
      slot = start(pane_id, now_ns, request);
      notice(pane_id);
    }

    auto& row = rows_[*slot];

    row.snapshot_begun = false;
    if (row.waiting) {
      return;
    }

    if (elapsed(now_ns, row.since_ns) >= healthy_window_ns) {
      row.resyncs = 0;
      row.since_ns = now_ns;
    }

    increment(row.resyncs);
    if (row.resyncs > requests_per_window) {
      row.due_ns = deadlineAfter(row.since_ns, healthy_window_ns << std::min(row.backoff, maximum_doublings));
      increment(row.backoff);
      setWaiting(*slot, true);
    } else {
      request(pane_id);
    }
  }

  void GraphicsPauses::resumeDue(std::uint64_t now_ns, PaneCall<void> request) {
    if (waiting_count_ == 0) {
      return;
    }

    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].waiting && now_ns >= rows_[slot].due_ns) {
        resume(slot, now_ns);
        request(rows_[slot].pane_id);
      }
    }
  }

  void GraphicsPauses::focus(Focus event, PaneCall<void> request) {
    const auto [pane_id, now_ns] = event;

    if (waiting_count_ == 0) {
      return;
    }

    const auto slot = find(pane_id);
    if (slot && rows_[*slot].waiting && elapsed(now_ns, rows_[*slot].since_ns) >= healthy_window_ns) {
      resume(*slot, now_ns);
      request(pane_id);
    }
  }

  void GraphicsPauses::snapshotApplied(std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept {
    const auto slot = find(pane_id);
    if (!slot) {
      return;
    }

    auto& row = rows_[*slot];

    if (phase == SnapshotPhase::begin) {
      row.snapshot_begun = true;
    } else if (row.snapshot_begun) {
      row.snapshot_begun = false;
      row.resumed_ns = now_ns;
      setWaiting(*slot, false);
      ++revision_;
    }
  }

  void GraphicsPauses::forgetClosed(PaneCall<bool> mirrored) {
    for (auto slot = count_; slot-- > 0;) {
      if (!mirrored(rows_[slot].pane_id)) {
        remove(slot);
      }
    }
  }

  void GraphicsPauses::reset() noexcept {
    if (count_ != 0) {
      count_ = 0;
      waiting_count_ = 0;
      ++revision_;
    }
  }

  std::uint64_t GraphicsPauses::elapsed(std::uint64_t now_ns, std::uint64_t since_ns) noexcept {
    return now_ns - std::min(now_ns, since_ns);
  }

  std::uint64_t GraphicsPauses::deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
    return now_ns + std::min(duration_ns, std::numeric_limits<std::uint64_t>::max() - now_ns);
  }

  void GraphicsPauses::increment(std::uint8_t& value) noexcept {
    if (value != std::numeric_limits<std::uint8_t>::max()) {
      ++value;
    }
  }

  ds::Option<std::size_t> GraphicsPauses::find(std::uint64_t pane_id) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].pane_id == pane_id) {
        return slot;
      }
    }

    return ds::none;
  }

  std::size_t GraphicsPauses::oldest() const noexcept {
    std::size_t found = 0;

    for (std::size_t slot = 1; slot < count_; ++slot) {
      const bool resumed = rows_[slot].resumed_ns.hasValue();
      const bool current_resumed = rows_[found].resumed_ns.hasValue();
      if ((resumed && !current_resumed) || (resumed == current_resumed && rows_[slot].since_ns < rows_[found].since_ns)) {
        found = slot;
      }
    }

    return found;
  }

  std::size_t GraphicsPauses::start(std::uint64_t pane_id, std::uint64_t now_ns, PaneCall<void> request) {
    if (count_ == capacity) {
      const auto slot = oldest();
      const auto evicted = rows_[slot];

      remove(slot);
      if (evicted.waiting) {
        request(evicted.pane_id);
      }
    }

    const auto slot = count_++;

    rows_[slot] = {.pane_id = pane_id, .since_ns = now_ns, .due_ns = now_ns};
    ++revision_;

    return slot;
  }

  void GraphicsPauses::remove(std::size_t slot) noexcept {
    setWaiting(slot, false);
    rows_[slot] = rows_[--count_];
    ++revision_;
  }

  void GraphicsPauses::setWaiting(std::size_t slot, bool waiting) noexcept {
    auto& row = rows_[slot];
    if (row.waiting != waiting) {
      row.waiting = waiting;
      if (waiting) {
        ++waiting_count_;
      } else {
        --waiting_count_;
      }

      ++revision_;
    }
  }

  void GraphicsPauses::resume(std::size_t slot, std::uint64_t now_ns) noexcept {
    auto& row = rows_[slot];

    row.resyncs = 1;
    row.since_ns = now_ns;
    row.snapshot_begun = false;
    setWaiting(slot, false);
  }

}
