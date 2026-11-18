module;
#include "tbc/annotations.hpp"

// The notices the window shows: each one's text, target and fade, and the few the center keeps.
export module telar.gui.features.notifications:center;

import std;

import telar.base.memory.containers;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/notification_item.cppm
export {
  namespace telar::gui::features::notifications {

    struct NotificationId {
      std::uint64_t value = 0;

      bool operator==(const NotificationId&) const noexcept = default;
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

      [[nodiscard]] static NotificationItem create(std::uint64_t now_ns, NotificationInput input);
      [[nodiscard]] bool same(const NotificationItem& other) const noexcept;
      [[nodiscard]] std::string_view linkHost() const noexcept;
      [[nodiscard]] bool clickable() const noexcept;
      bool beginExit(std::uint64_t now_ns) noexcept;
      bool advance(std::uint64_t now_ns) noexcept;
      [[nodiscard]] std::uint64_t nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const noexcept;
      [[nodiscard]] float opacity() const noexcept;
      [[nodiscard]] float opacity(std::uint64_t now_ns) const noexcept;

    private:
      template <std::size_t Capacity>
      static void copyText(runtime::FixedText<Capacity>& destination, std::string_view text);

      bool advanceEntering(std::uint64_t now_ns) noexcept;
      bool advanceExiting(std::uint64_t now_ns) noexcept;
    };

  }
}

// Interface: application/notification_center.cppm
export {
  namespace telar::gui::features::notifications {

    class NotificationCenter {
    public:
      static constexpr std::size_t capacity = 4;

      explicit NotificationCenter(std::uint64_t first_id = 1) noexcept;

      [[nodiscard]] std::span<const NotificationItem> items() const noexcept;
      [[nodiscard]] const NotificationItem* find(NotificationId id) const noexcept;
      NotificationId push(std::uint64_t now_ns, NotificationInput input);
      bool advance(std::uint64_t now_ns) noexcept;
      bool dismiss(NotificationId id, std::uint64_t now_ns) noexcept;
      [[nodiscard]] ds::Option<NotificationTarget> activate(NotificationId id, std::uint64_t now_ns) noexcept;
      [[nodiscard]] ds::Option<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const;

    private:
      std::array<NotificationItem, capacity> items_;
      std::size_t count_ = 0;
      std::uint64_t next_id_;
    };

  }
}
