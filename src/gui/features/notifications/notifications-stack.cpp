module telar.gui.features.notifications;

import std;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::notifications {

  void NotificationActionLabel::format(std::string_view host, bool truncated, Buffer& buffer) {
    buffer.truncate(0);
    buffer.append(truncated ? "Open …" : "Open ");
    buffer.append(host);
    buffer.append(" ↗");
  }

  float NotificationMetrics::px(float value) const noexcept {
    return value * ratio;
  }

  float NotificationMetrics::height(std::size_t body_lines, bool clickable) const noexcept {
    auto height = px(vertical_padding) + title_row;

    if (body_lines > 0) {
      height += px(body_gap) + (static_cast<float>(body_lines) * body_row);
    }

    if (clickable) {
      height += px(action_gap) + small_row;
    }

    return std::max(height, px(minimum_card_height));
  }

  Rect NotificationCardGeometry::icon() const noexcept {
    return {.x = bounds.x + metrics.px(NotificationMetrics::card_padding), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = metrics.px(NotificationMetrics::icon_side), .height = metrics.px(NotificationMetrics::icon_side)};
  }

  Rect NotificationCardGeometry::title() const noexcept {
    return {.x = textLeft(), .y = bounds.y + metrics.px(NotificationMetrics::card_padding), .width = bounds.width - metrics.px(NotificationMetrics::title_insets), .height = metrics.title_row};
  }

  Rect NotificationCardGeometry::body(std::size_t row) const noexcept {
    auto y = bounds.y + metrics.px(NotificationMetrics::body_top) + metrics.title_row;

    for (std::size_t index = 0; index < row; ++index) {
      y += metrics.body_row;
    }

    return {.x = textLeft(), .y = y, .width = bodyWidth(), .height = metrics.body_row};
  }

  Rect NotificationCardGeometry::action() const noexcept {
    return {.x = textLeft(), .y = bounds.y + bounds.height - metrics.px(NotificationMetrics::card_padding) - metrics.small_row, .width = bodyWidth(), .height = metrics.small_row};
  }

  Rect NotificationCardGeometry::close() const noexcept {
    return {.x = bounds.x + bounds.width - metrics.px(NotificationMetrics::close_right), .y = bounds.y + metrics.px(NotificationMetrics::close_top), .width = metrics.px(NotificationMetrics::close_side), .height = metrics.px(NotificationMetrics::close_side)};
  }

  Rect NotificationCardGeometry::actionUnderline(float line_height, float advance) const noexcept {
    const auto row = action();
    const auto top = std::floor(row.y + ((row.height - line_height) / 2));

    return {.x = row.x, .y = top + line_height - NotificationMetrics::underline_bottom, .width = std::min(row.width, advance), .height = NotificationMetrics::underline_height};
  }

  float NotificationCardGeometry::bodyWidth() const noexcept {
    return bounds.width - metrics.px(NotificationMetrics::text_insets);
  }

  float NotificationCardGeometry::textLeft() const noexcept {
    return bounds.x + metrics.px(NotificationMetrics::text_left);
  }

  std::span<const NotificationPlacement> NotificationStack::Cards::items() const noexcept {
    return std::span{placements}.first(count);
  }

  ds::Option<std::uint64_t> NotificationStack::nextDeadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    ds::Option<std::uint64_t> earliest;

    for (const auto& motion : motions_) {
      if (motion.id.value == 0 || std::equal_to<>{}(motion.from, motion.to) || (now_ns >= motion.started_ns && now_ns - motion.started_ns >= motion_duration_ns)) {
        continue;
      }

      const auto deadline = std::min(NotificationItem::deadlineAfter(now_ns, interval_ns), NotificationItem::deadlineAfter(motion.started_ns, motion_duration_ns));

      earliest = earliest ? std::min(*earliest, deadline) : deadline;
    }

    return earliest;
  }

  float NotificationStack::Motion::position(float target, const NotificationStackRequest& frame) noexcept {
    const auto now_ns = frame.now_ns;

    if (std::not_equal_to<>{}(to, target)) {
      from = value(now_ns);
      to = target;
      started_ns = now_ns;
    }

    return value(now_ns);
  }

  float NotificationStack::Motion::value(std::uint64_t now_ns) const noexcept {
    constexpr float quadratic_weight = 3;
    constexpr float cubic_weight = 2;
    const auto elapsed = now_ns >= started_ns ? std::min(now_ns - started_ns, motion_duration_ns) : 0;
    const auto phase = static_cast<float>(elapsed) / static_cast<float>(motion_duration_ns);

    return from + ((to - from) * phase * phase * (quadratic_weight - (cubic_weight * phase)));
  }

  ds::Option<std::size_t> NotificationStack::motion(NotificationId id, float y) noexcept {
    const auto* const found = std::ranges::find(motions_, id, &Motion::id);
    if (found != motions_.end()) {
      return static_cast<std::size_t>(found - motions_.begin());
    }

    constexpr NotificationId invalid;
    const auto motions = motions_.viewMut();
    const auto vacant = std::ranges::find(motions, invalid, &Motion::id);
    if (vacant == motions.end()) {
      return ds::none;
    }

    *vacant = {.id = id, .from = y, .to = y};

    return static_cast<std::size_t>(vacant - motions.begin());
  }

}
