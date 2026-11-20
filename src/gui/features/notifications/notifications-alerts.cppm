module;
#include "tbc/annotations.hpp"

// The notices agents raise when they need input, finish or fail, one each or folded into a
// summary when more change at once than the center keeps.
export module telar.gui.features.notifications:alerts;

import std;
import telar.tbc;

import :center;
import telar.gui.foundation.model;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/agent_alerts.cppm
export {
  namespace telar::gui::features::notifications {

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
      [[nodiscard]] static tbc::val_a<ds::Option<NotificationInput>> input(const AgentStatusChange& change, std::string_view label, tbc::mut_a<Message> message);

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
        case AgentStatus::unknown:
        case AgentStatus::working:
          break;
        }

        // An unknown or working agent, or a status outside the enum.
        return "active";
      }

      [[nodiscard]] static constexpr std::string_view title(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return "Agent needs input";
        case AgentStatus::done:
          return "Agent done";
        case AgentStatus::failed:
          return "Agent failed";
        case AgentStatus::unknown:
        case AgentStatus::working:
        case AgentStatus::ready:
          break;
        }

        // A status that raises no alert, or one outside the enum.
        return {};
      }

      [[nodiscard]] static constexpr NotificationLevel level(AgentStatus status) noexcept {
        switch (status) {
        case AgentStatus::blocked:
          return NotificationLevel::warning;
        case AgentStatus::failed:
          return NotificationLevel::failure;
        case AgentStatus::unknown:
        case AgentStatus::working:
        case AgentStatus::ready:
        case AgentStatus::done:
          break;
        }

        // A status that needs nothing, or one outside the enum.
        return NotificationLevel::success;
      }

      [[nodiscard]] static constexpr std::uint64_t duration(AgentStatus status) noexcept {
        return status == AgentStatus::failed ? failed_duration_ns : NotificationInput::default_duration_ns;
      }

      [[nodiscard]] static tbc::val_a<std::string_view> formatMessage(const AgentStatusChange& change, std::string_view label, tbc::mut_a<Message> message);
      void add(AgentStatus status) noexcept;
      [[nodiscard]] tbc::val_a<ds::Option<NotificationInput>> summary(tbc::mut_a<Message> message) const;
      static void appendCount(Message& message, std::size_t count, AgentStatus status, bool separated);

      std::size_t blocked_ = 0;
      std::size_t done_ = 0;
      std::size_t failed_ = 0;
    };

  }
}
