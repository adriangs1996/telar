#pragma once

#include "notification_item.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>

namespace telar::gui {

class NotificationCenter {
public:
  static constexpr std::size_t capacity = 4;

  explicit NotificationCenter(std::uint64_t first_id = 1) noexcept
      : next_id_(first_id) {}

  [[nodiscard]] std::span<const NotificationItem> items() const noexcept {
    return std::span{items_}.first(count_);
  }

  [[nodiscard]] const NotificationItem *find(NotificationId id) const noexcept {
    const auto current = items();
    const auto found = std::ranges::find(current, id, &NotificationItem::id);

    return found == current.end() ? nullptr : &*found;
  }

  NotificationId push(std::uint64_t now_ns, NotificationInput input) {
    auto item = NotificationItem::create(now_ns, input);
    for (auto &existing : std::span{items_}.first(count_)) {
      if (existing.phase == NotificationItem::Phase::exiting || !existing.same(item)) {
        continue;
      }

      const auto started = existing.phase == NotificationItem::Phase::entering ? NotificationItem::deadlineAfter(now_ns, NotificationItem::transition_duration_ns) : now_ns;
      existing.expires_at_ns = NotificationItem::deadlineAfter(started, input.duration_ns);

      return existing.id;
    }

    if (next_id_ == 0) {
      next_id_ = 1;
    }

    item.id = NotificationId{next_id_++};
    count_ = std::min(count_, capacity - 1);
    std::move_backward(items_.begin(), items_.begin() + static_cast<std::ptrdiff_t>(count_), items_.begin() + static_cast<std::ptrdiff_t>(count_ + 1));
    items_.front() = item;
    ++count_;

    return item.id;
  }

  bool advance(std::uint64_t now_ns) noexcept {
    bool changed = false;
    std::size_t index = 0;
    while (index < count_) {
      auto &item = items_[index];
      changed = item.advance(now_ns) || changed;
      if (item.phase == NotificationItem::Phase::exiting && item.transition_position_ns == 0) {
        const auto tail = std::span{items_}.subspan(index + 1, count_ - index - 1);
        std::ranges::move(tail, items_.begin() + static_cast<std::ptrdiff_t>(index));
        --count_;
        changed = true;
      } else {
        ++index;
      }
    }

    return changed;
  }

  bool dismiss(NotificationId id, std::uint64_t now_ns) noexcept {
    for (auto &item : std::span{items_}.first(count_)) {
      if (item.id == id) {
        return item.beginExit(now_ns);
      }
    }

    return false;
  }

  [[nodiscard]] std::optional<NotificationTarget> activate(NotificationId id, std::uint64_t now_ns) noexcept {
    for (auto &item : std::span{items_}.first(count_)) {
      if (item.id == id && item.beginExit(now_ns)) {
        return item.target;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] std::optional<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const {
    if (frame_interval_ns == 0) {
      throw std::invalid_argument{"InvalidNotificationFrameInterval"};
    }

    if (count_ == 0) {
      return std::nullopt;
    }

    auto deadline = std::numeric_limits<std::uint64_t>::max();
    for (const auto &item : items()) {
      deadline = std::min(deadline, item.nextDeadline(now_ns, frame_interval_ns));
    }

    return deadline;
  }

private:
  std::array<NotificationItem, capacity> items_;
  std::size_t count_ = 0;
  std::uint64_t next_id_;
};

}
