#pragma once

#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "core/geometry.hpp"
#include "notification_geometry.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct NotificationPlacement {
  std::size_t index = 0;
  NotificationId id{};
  Rect bounds;
  float opacity = 0;
};

struct NotificationStackRequest {
  std::span<const NotificationItem> items;
  Rect host;
  float ratio = 1;
  std::uint64_t now_ns = 0;
};

template <typename Hidden>
concept NotificationHidden = requires(Hidden &hidden, const NotificationItem &item) {
  { hidden(item) } -> std::convertible_to<bool>;
};

template <typename Measure>
concept NotificationHeight = requires(Measure &measure, const NotificationItem &item, float width) {
  { measure(item, width) } -> std::convertible_to<float>;
};

class NotificationStack {
public:
  static constexpr std::size_t maximum_visible = 2;
  static constexpr std::uint64_t motion_duration_ns = 180'000'000;

  struct Cards {
    std::array<NotificationPlacement, maximum_visible> placements;
    std::size_t count = 0;

    [[nodiscard]] std::span<const NotificationPlacement> items() const noexcept {
      return std::span{placements}.first(count);
    }
  };

  template <NotificationHidden Hidden, NotificationHeight Measure>
  [[nodiscard]] Cards prepare(NotificationStackRequest request, Hidden hidden, Measure measure) {
    Cards result;
    const auto margin = NotificationMetrics::margin * request.ratio;
    const auto width = std::min(NotificationMetrics::preferred_width * request.ratio, request.host.width - (2 * margin));
    if (width < NotificationMetrics::minimum_width * request.ratio || request.host.height < NotificationMetrics::minimum_host_height * request.ratio) {
      motions_ = {};
      return result;
    }

    std::array<bool, NotificationCenter::capacity> used{};
    auto y = request.host.y + margin;
    std::size_t painted = 0;
    std::array<NotificationPlacement, maximum_visible> cards;
    for (std::size_t index = 0; index < request.items.size() && painted < maximum_visible; ++index) {
      const auto &item = request.items[index];
      if (hidden(item) || (item.phase == NotificationItem::Phase::exiting && item.transition_position_ns == 0)) {
        continue;
      }

      Rect bounds{.x = request.host.x + request.host.width - margin - width, .y = y, .width = width, .height = measure(item, width)};
      if (y + bounds.height > request.host.y + request.host.height - margin) {
        break;
      }

      const auto opacity = item.opacity(request.now_ns);
      if (opacity == 0 && item.phase == NotificationItem::Phase::exiting) {
        continue;
      }

      if (const auto slot = motion(item.id, y)) {
        used[*slot] = true;
        bounds.y = motions_[*slot].position(y, request);
      }

      bounds.x += NotificationMetrics::enter_shift_x * request.ratio * (1 - opacity);
      bounds.y += NotificationMetrics::enter_shift_y * request.ratio * (1 - opacity);
      y += bounds.height + (NotificationMetrics::stack_gap * request.ratio);
      cards[painted++] = {.index = index, .id = item.id, .bounds = bounds, .opacity = opacity};
    }

    while (painted > 0) {
      const auto &card = cards[--painted];
      if (card.opacity > 0) {
        result.placements[result.count++] = card;
      }
    }

    for (std::size_t index = 0; index < motions_.size(); ++index) {
      if (!used[index]) {
        motions_[index] = {};
      }
    }

    return result;
  }

  [[nodiscard]] std::optional<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    std::optional<std::uint64_t> earliest;
    for (const auto &motion : motions_) {
      if (motion.id.value == 0 || motion.from == motion.to || (now_ns >= motion.started_ns && now_ns - motion.started_ns >= motion_duration_ns)) {
        continue;
      }

      const auto deadline = std::min(NotificationItem::deadlineAfter(now_ns, interval_ns), NotificationItem::deadlineAfter(motion.started_ns, motion_duration_ns));
      earliest = earliest ? std::min(*earliest, deadline) : deadline;
    }

    return earliest;
  }

private:
  struct Motion {
    NotificationId id{};
    float from = 0;
    float to = 0;
    std::uint64_t started_ns = 0;

    float position(float target, const NotificationStackRequest &frame) noexcept {
      const auto now_ns = frame.now_ns;
      if (to != target) {
        from = value(now_ns);
        to = target;
        started_ns = now_ns;
      }

      return value(now_ns);
    }

    [[nodiscard]] float value(std::uint64_t now_ns) const noexcept {
      constexpr float quadratic_weight = 3;
      constexpr float cubic_weight = 2;
      const auto elapsed = now_ns >= started_ns ? std::min(now_ns - started_ns, motion_duration_ns) : 0;
      const auto phase = static_cast<float>(elapsed) / static_cast<float>(motion_duration_ns);

      return from + ((to - from) * phase * phase * (quadratic_weight - (cubic_weight * phase)));
    }
  };

  [[nodiscard]] std::optional<std::size_t> motion(NotificationId id, float y) noexcept {
    auto *const found = std::ranges::find(motions_, id, &Motion::id);
    if (found != motions_.end()) {
      return static_cast<std::size_t>(found - motions_.begin());
    }

    constexpr NotificationId invalid;
    auto *const vacant = std::ranges::find(motions_, invalid, &Motion::id);
    if (vacant == motions_.end()) {
      return std::nullopt;
    }

    *vacant = {.id = id, .from = y, .to = y};

    return static_cast<std::size_t>(vacant - motions_.begin());
  }

  std::array<Motion, NotificationCenter::capacity> motions_{};
};

}
