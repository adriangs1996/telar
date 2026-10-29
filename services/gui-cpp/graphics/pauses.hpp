#pragma once

#include "application/pane_layout.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <utility>

namespace telar::gui {

class GraphicsPauses {
public:
  static constexpr std::size_t capacity = PaneLayout::maximum_panes;
  static constexpr std::uint64_t healthy_window_ns = 60'000'000'000;
  static constexpr std::uint8_t requests_per_window = 3;
  static constexpr std::uint8_t maximum_doublings = 4;

  struct Focus {
    std::uint64_t pane_id = 0;
    std::uint64_t now_ns = 0;
  };

  struct Row {
    std::uint64_t pane_id = 0;
    std::uint64_t since_ns = 0;
    std::uint64_t due_ns = 0;
    std::optional<std::uint64_t> resumed_ns = std::nullopt;
    std::uint8_t resyncs = 0;
    std::uint8_t backoff = 0;
    bool waiting = false;
    bool snapshot_begun = false;
  };

  [[nodiscard]] bool contains(std::uint64_t pane_id) const noexcept {
    const auto slot = find(pane_id);

    return slot && !rows_[*slot].resumed_ns;
  }

  [[nodiscard]] std::span<const Row> rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::optional<std::uint64_t> nextDeadline() const noexcept {
    if (waiting_count_ == 0) {
      return std::nullopt;
    }

    auto earliest = std::numeric_limits<std::uint64_t>::max();
    for (const auto &row : rows()) {
      if (row.waiting) {
        earliest = std::min(earliest, row.due_ns);
      }
    }

    return earliest;
  }

  template <typename Request, typename Notice>
    requires std::invocable<const Request &, std::uint64_t> && std::invocable<const Notice &, std::uint64_t>
  void pause(std::uint64_t pane_id, std::uint64_t now_ns, const Request &request, const Notice &notice) {
    auto slot = find(pane_id);
    if (slot) {
      auto &row = rows_[*slot];
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

    auto &row = rows_[*slot];
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
      setWaiting(row, true);
    } else {
      request(pane_id);
    }
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  void resumeDue(std::uint64_t now_ns, const Request &request) {
    if (waiting_count_ == 0) {
      return;
    }

    for (auto &row : std::span{rows_}.first(count_)) {
      if (row.waiting && now_ns >= row.due_ns) {
        resume(row, now_ns);
        request(row.pane_id);
      }
    }
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  void focus(Focus event, const Request &request) {
    const auto [pane_id, now_ns] = event;
    if (waiting_count_ == 0) {
      return;
    }

    const auto slot = find(pane_id);
    if (slot && rows_[*slot].waiting && elapsed(now_ns, rows_[*slot].since_ns) >= healthy_window_ns) {
      auto &row = rows_[*slot];
      resume(row, now_ns);
      request(row.pane_id);
    }
  }

  void snapshotApplied(std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept {
    const auto slot = find(pane_id);
    if (!slot) {
      return;
    }

    auto &row = rows_[*slot];
    if (phase == SnapshotPhase::begin) {
      row.snapshot_begun = true;
    } else if (row.snapshot_begun) {
      row.snapshot_begun = false;
      setWaiting(row, false);
      row.resumed_ns = now_ns;
      ++revision_;
    }
  }

  template <typename Mirrored>
    requires std::predicate<const Mirrored &, std::uint64_t>
  void forgetClosed(const Mirrored &mirrored) {
    for (auto slot = count_; slot-- > 0;) {
      if (!mirrored(rows_[slot].pane_id)) {
        remove(slot);
      }
    }
  }

  void reset() noexcept {
    if (count_ != 0) {
      count_ = 0;
      waiting_count_ = 0;
      ++revision_;
    }
  }

private:
  [[nodiscard]] static std::uint64_t elapsed(std::uint64_t now_ns, std::uint64_t since_ns) noexcept {
    return now_ns - std::min(now_ns, since_ns);
  }

  [[nodiscard]] static std::uint64_t deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
    return now_ns + std::min(duration_ns, std::numeric_limits<std::uint64_t>::max() - now_ns);
  }

  static void increment(std::uint8_t &value) noexcept {
    if (value != std::numeric_limits<std::uint8_t>::max()) {
      ++value;
    }
  }

  [[nodiscard]] std::optional<std::size_t> find(std::uint64_t pane_id) const noexcept {
    for (std::size_t slot = 0; slot < count_; ++slot) {
      if (rows_[slot].pane_id == pane_id) {
        return slot;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] std::size_t oldest() const noexcept {
    std::size_t found = 0;
    for (std::size_t slot = 1; slot < count_; ++slot) {
      const bool resumed = rows_[slot].resumed_ns.has_value();
      const bool current_resumed = rows_[found].resumed_ns.has_value();
      if ((resumed && !current_resumed) || (resumed == current_resumed && rows_[slot].since_ns < rows_[found].since_ns)) {
        found = slot;
      }
    }

    return found;
  }

  template <typename Request>
    requires std::invocable<const Request &, std::uint64_t>
  std::size_t start(std::uint64_t pane_id, std::uint64_t now_ns, const Request &request) {
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

  void remove(std::size_t slot) noexcept {
    setWaiting(rows_[slot], false);
    rows_[slot] = rows_[--count_];
    ++revision_;
  }

  void setWaiting(Row &row, bool waiting) noexcept {
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

  void resume(Row &row, std::uint64_t now_ns) noexcept {
    row.resyncs = 1;
    row.since_ns = now_ns;
    row.snapshot_begun = false;
    setWaiting(row, false);
  }

  std::array<Row, capacity> rows_{};
  std::size_t count_ = 0;
  std::size_t waiting_count_ = 0;
  std::uint64_t revision_ = 0;
};

}
