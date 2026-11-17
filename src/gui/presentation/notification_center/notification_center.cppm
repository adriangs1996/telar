module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.notification_center;

import std;
import telar.tbc;

import telar.gui.foundation.model;
import telar.gui.foundation.text;
import telar.base.memory.containers;
import telar.wire.vocabulary;

// Interface: application/notification_item.cppm
export {
  namespace telar::gui {

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
  namespace telar::gui {

    class NotificationCenter {
    public:
      static constexpr std::size_t capacity = 4;

      explicit NotificationCenter(std::uint64_t first_id = 1) noexcept;

      [[nodiscard]] std::span<const NotificationItem> items() const noexcept;
      [[nodiscard]] const NotificationItem* find(NotificationId id) const noexcept;
      NotificationId push(std::uint64_t now_ns, NotificationInput input);
      bool advance(std::uint64_t now_ns) noexcept;
      bool dismiss(NotificationId id, std::uint64_t now_ns) noexcept;
      [[nodiscard]] std::optional<NotificationTarget> activate(NotificationId id, std::uint64_t now_ns) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> nextDeadline(std::uint64_t now_ns, std::uint64_t frame_interval_ns) const;

    private:
      std::array<NotificationItem, capacity> items_;
      std::size_t count_ = 0;
      std::uint64_t next_id_;
    };

  }
}

// Interface: application/agent_alerts.cppm
export {
  namespace telar::gui {

    template <typename Resolve>
    concept AgentAlertLabel = requires(Resolve& resolve, AgentStatusChange change) {
      { resolve(change) } -> std::convertible_to<std::string_view>;
    };

    template <typename Publish>
    concept NotificationPublisher = requires(Publish& publish, NotificationInput input) {
      publish(input);
    };

    class AgentAlerts {
    public:
      static constexpr std::size_t message_capacity = 96;
      static constexpr std::uint64_t failed_duration_ns = 7'000'000'000;
      using Message = BoundedText<message_capacity>;

      [[nodiscard]] static constexpr bool alertable(const AgentStatusChange& change) noexcept {
        return change.current == AgentStatus::blocked || change.current == AgentStatus::done || change.current == AgentStatus::failed;
      }

      // The input's message is written into the message, region `a`; its title is a literal.
      [[nodiscard]] static tbc::view<std::optional<NotificationInput>, tbc::lt::a> input(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message);

      // Generic over the caller's label and publisher, so it stays here.
      template <AgentAlertLabel Resolve, NotificationPublisher Publish>
      TBC_GENERIC static std::size_t publish(std::span<const AgentStatusChange> changes, Resolve resolve, Publish publish_notification) {
        const auto count = static_cast<std::size_t>(std::ranges::count_if(changes, alertable));
        const auto individual = count > NotificationCenter::capacity ? NotificationCenter::capacity - 1 : count;
        std::size_t published = 0;
        AgentAlerts folded;

        for (const auto& change : changes) {
          if (!alertable(change)) {
            continue;
          }

          if (published == individual) {
            folded.add(change.current);
            continue;
          }

          Message message;
          if (const auto alert = input(change, resolve(change), message)) {
            publish_notification(*alert);
            ++published;
          }
        }

        Message message;
        if (const auto summary = folded.summary(message)) {
          publish_notification(*summary);
          ++published;
        }

        return published;
      }

    private:
      [[nodiscard]] static constexpr std::string_view statusName(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return "waiting for input";
        case AgentStatus::done:
          return "done";
        case AgentStatus::failed:
          return "failed";
        case AgentStatus::ready:
          return "ready";
        default:
          return "active";
        }
      }

      [[nodiscard]] static constexpr std::string_view title(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return "Agent needs input";
        case AgentStatus::done:
          return "Agent done";
        case AgentStatus::failed:
          return "Agent failed";
        default:
          return {};
        }
      }

      [[nodiscard]] static constexpr NotificationLevel level(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return NotificationLevel::warning;
        case AgentStatus::failed:
          return NotificationLevel::failure;
        default:
          return NotificationLevel::success;
        }
      }

      [[nodiscard]] static constexpr std::uint64_t duration(AgentStatus status) noexcept {
        return status == AgentStatus::failed ? failed_duration_ns : NotificationInput::default_duration_ns;
      }

      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> formatMessage(const AgentStatusChange& change, std::string_view label, tbc::view<Message&, tbc::lt::a> message);
      void add(AgentStatus status) noexcept;
      [[nodiscard]] tbc::view<std::optional<NotificationInput>, tbc::lt::a> summary(tbc::view<Message&, tbc::lt::a> message) const;
      static void appendCount(Message& message, std::size_t count, AgentStatus status, bool separated);

      std::size_t blocked_ = 0;
      std::size_t done_ = 0;
      std::size_t failed_ = 0;
    };

  }
}
