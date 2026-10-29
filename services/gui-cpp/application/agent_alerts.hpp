#pragma once

#include "agent_status_change.hpp"
#include "notification_center.hpp"
#include "notification_item.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <typename Resolve>
concept AgentAlertLabel = requires(Resolve &resolve, AgentStatusChange change) {
  { resolve(change) } -> std::convertible_to<std::string_view>;
};

template <typename Publish>
concept NotificationPublisher = requires(Publish &publish, NotificationInput input) {
  publish(input);
};

class AgentAlerts {
public:
  static constexpr std::size_t message_capacity = 96;
  static constexpr std::uint64_t failed_duration_ns = 7'000'000'000;
  using Message = BoundedText<message_capacity>;

  [[nodiscard]] static constexpr bool alertable(const AgentStatusChange &change) noexcept {
    return change.current == AgentStatus::blocked || change.current == AgentStatus::done || change.current == AgentStatus::failed;
  }

  [[nodiscard]] static std::optional<NotificationInput> input(const AgentStatusChange &change, std::string_view label, Message &message) {
    if (!alertable(change)) {
      return std::nullopt;
    }

    const auto text = formatMessage(change, label, message);

    return NotificationInput{.level = level(change.current), .target = {.kind = NotificationTarget::Kind::pane, .id = change.pane_id}, .title = title(change.current), .message = text, .link = {}, .duration_ns = duration(change.current)};
  }

  template <AgentAlertLabel Resolve, NotificationPublisher Publish>
  static std::size_t publish(std::span<const AgentStatusChange> changes, Resolve resolve, Publish publish_notification) {
    const auto count = static_cast<std::size_t>(std::ranges::count_if(changes, alertable));
    const auto individual = count > NotificationCenter::capacity ? NotificationCenter::capacity - 1 : count;
    std::size_t published = 0;
    AgentAlerts folded;
    for (const auto &change : changes) {
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

  [[nodiscard]] static std::string_view formatMessage(const AgentStatusChange &change, std::string_view label, Message &message) {
    message.truncate(0);
    try {
      message.append(label);
      message.append(" in pane ");
      message.appendDecimal(change.pane_index);
      message.append(" is ");
      message.append(statusName(change.current));

      return message.view();
    } catch (const std::length_error &) {
      return "Agent status changed";
    }
  }

  void add(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::blocked:
      ++blocked_;
      break;
    case AgentStatus::done:
      ++done_;
      break;
    case AgentStatus::failed:
      ++failed_;
      break;
    default:
      break;
    }
  }

  [[nodiscard]] std::optional<NotificationInput> summary(Message &message) const {
    const auto total = blocked_ + done_ + failed_;
    if (total == 0) {
      return std::nullopt;
    }

    message.appendDecimal(total);
    message.append(" more agents:");
    appendCount(message, blocked_, AgentStatus::blocked, false);
    appendCount(message, done_, AgentStatus::done, blocked_ != 0);
    appendCount(message, failed_, AgentStatus::failed, blocked_ + done_ != 0);
    auto severity = AgentStatus::done;
    if (blocked_ != 0) {
      severity = AgentStatus::blocked;
    }

    if (failed_ != 0) {
      severity = AgentStatus::failed;
    }

    return NotificationInput{.level = level(severity), .title = "More agents changed", .message = message.view(), .link = {}, .duration_ns = duration(severity)};
  }

  static void appendCount(Message &message, std::size_t count, AgentStatus status, bool separated) {
    if (count == 0) {
      return;
    }

    message.append(separated ? ", " : " ");
    message.appendDecimal(count);
    message.append(" ");
    message.append(statusName(status));
  }

  std::size_t blocked_ = 0;
  std::size_t done_ = 0;
  std::size_t failed_ = 0;
};

}
