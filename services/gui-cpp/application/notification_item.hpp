#pragma once

#include "core/smoothstep.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::gui {

struct NotificationId {
  std::uint64_t value = 0;

  bool operator==(const NotificationId &) const noexcept = default;
};

struct NotificationInput {
  static constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
  static constexpr std::uint64_t default_duration_ns = default_notification_duration_ms * nanoseconds_per_millisecond;
  NotificationLevel level = NotificationLevel::info;
  NotificationTarget target{};
  std::string_view title;
  std::string_view message;
  std::string_view link;
  std::uint64_t duration_ns = default_duration_ns;
};

struct NotificationItem {
  enum class Phase : std::uint8_t {
    entering,
    visible,
    exiting,
  };

  static constexpr std::uint64_t transition_duration_ns = 200'000'000;
  NotificationId id{};
  NotificationLevel level = NotificationLevel::info;
  NotificationTarget target{};
  runtime::FixedText<max_notification_title_bytes> title;
  runtime::FixedText<max_notification_message_bytes> message;
  runtime::FixedText<max_notification_link_bytes> link;
  Phase phase = Phase::entering;
  std::uint64_t transition_position_ns = 0;
  std::uint64_t transition_updated_ns = 0;
  std::uint64_t expires_at_ns = 0;

  [[nodiscard]] static constexpr std::uint64_t deadlineAfter(std::uint64_t now_ns, std::uint64_t duration_ns) noexcept {
    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, duration_ns);
  }

  [[nodiscard]] static NotificationItem create(std::uint64_t now_ns, NotificationInput input) {
    NotificationItem item;
    item.level = input.level;
    item.target = input.target;
    item.transition_updated_ns = now_ns;
    item.expires_at_ns = deadlineAfter(deadlineAfter(now_ns, transition_duration_ns), input.duration_ns);
    copyText(item.title, input.title);
    copyText(item.message, input.message);
    if (input.link.size() <= max_notification_link_bytes) {
      item.link.assign(input.link);
    }

    return item;
  }

  [[nodiscard]] bool same(const NotificationItem &other) const noexcept {
    const auto same_target = target.kind == other.target.kind && (target.kind == NotificationTarget::Kind::none || target.id == other.target.id);

    return level == other.level && same_target && title.view() == other.title.view() && message.view() == other.message.view() && link.view() == other.link.view();
  }

  [[nodiscard]] std::string_view linkHost() const noexcept {
    return notificationLinkHost(link.view());
  }

  [[nodiscard]] bool clickable() const noexcept {
    return target.kind != NotificationTarget::Kind::none || !link.view().empty();
  }

  bool beginExit(std::uint64_t now_ns) noexcept {
    if (phase == Phase::exiting) {
      return false;
    }

    if (phase == Phase::entering) {
      advanceEntering(now_ns);
    }

    phase = Phase::exiting;
    transition_updated_ns = now_ns;

    return true;
  }

  bool advance(std::uint64_t now_ns) noexcept {
    bool changed = false;
    if (phase == Phase::entering) {
      changed = advanceEntering(now_ns);
    }

    if (phase == Phase::visible && now_ns >= expires_at_ns) {
      phase = Phase::exiting;
      transition_updated_ns = expires_at_ns;
      changed = true;
    }

    if (phase == Phase::exiting) {
      changed = advanceExiting(now_ns) || changed;
    }

    return changed;
  }

  [[nodiscard]] std::uint64_t nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const noexcept {
    switch (phase) {
    case Phase::entering:
      return std::min(deadlineAfter(now_ns, frame_interval_ns), deadlineAfter(transition_updated_ns, transition_duration_ns - transition_position_ns));
    case Phase::visible:
      return expires_at_ns;
    case Phase::exiting:
      return std::min(deadlineAfter(now_ns, frame_interval_ns), deadlineAfter(transition_updated_ns, transition_position_ns));
    }

    return now_ns;
  }

  [[nodiscard]] float opacity() const noexcept {
    const auto position = static_cast<float>(transition_position_ns) / static_cast<float>(transition_duration_ns);

    return smoothstep(position);
  }

  [[nodiscard]] float opacity(std::uint64_t now_ns) const noexcept {
    auto sampled = *this;
    sampled.advance(now_ns);

    return sampled.opacity();
  }

private:
  template <std::size_t Capacity>
  static void copyText(runtime::FixedText<Capacity> &destination, std::string_view text) {
    constexpr std::string_view invalid_text = "invalid notification text";
    const auto valid = inspectUtf8(text) == Utf8Validation::valid ? text : invalid_text;
    destination.assign(runtime::utf8Prefix(valid, Capacity));
  }

  bool advanceEntering(std::uint64_t now_ns) noexcept {
    if (now_ns <= transition_updated_ns) {
      return false;
    }

    const auto previous = transition_position_ns;
    transition_position_ns = std::min(transition_duration_ns, deadlineAfter(previous, now_ns - transition_updated_ns));
    transition_updated_ns = now_ns;
    if (transition_position_ns == transition_duration_ns) {
      phase = Phase::visible;
    }

    return transition_position_ns != previous;
  }

  bool advanceExiting(std::uint64_t now_ns) noexcept {
    if (now_ns <= transition_updated_ns) {
      return false;
    }

    const auto previous = transition_position_ns;
    transition_position_ns -= std::min(transition_position_ns, now_ns - transition_updated_ns);
    transition_updated_ns = now_ns;

    return transition_position_ns != previous;
  }
};

}
