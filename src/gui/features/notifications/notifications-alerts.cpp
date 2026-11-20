module telar.gui.features.notifications;

import std;
import telar.tbc;
import telar.gui.foundation.model;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::notifications {

  tbc::val_a<ds::Option<NotificationInput>> AgentAlerts::input(const AgentStatusChange& change, std::string_view label, tbc::mut_a<Message> message) {
    if (!alertable(change)) {
      return ds::none;
    }

    const auto text = formatMessage(change, label, message);

    return NotificationInput{.level = level(change.current), .target = {.kind = NotificationTarget::Kind::pane, .id = change.pane_id}, .title = title(change.current), .message = text, .link = {}, .duration_ns = duration(change.current)};
  }

  tbc::val_a<std::string_view> AgentAlerts::formatMessage(const AgentStatusChange& change, std::string_view label, tbc::mut_a<Message> message) {
    message.truncate(0);
    try {
      message.append(label);
      message.append(" in pane ");
      message.appendDecimal(change.pane_index);
      message.append(" is ");
      message.append(statusName(change.current));

      return message.view();
    } catch (const std::length_error&) {
      return "Agent status changed";
    }
  }

  void AgentAlerts::add(AgentStatus status) noexcept {
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
    case AgentStatus::unknown:
    case AgentStatus::working:
    case AgentStatus::ready:
      break;
    }
  }

  tbc::val_a<ds::Option<NotificationInput>> AgentAlerts::summary(tbc::mut_a<Message> message) const {
    const auto total = blocked_ + done_ + failed_;
    if (total == 0) {
      return ds::none;
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

  void AgentAlerts::appendCount(Message& message, std::size_t count, AgentStatus status, bool separated) {
    if (count == 0) {
      return;
    }

    message.append(separated ? ", " : " ");
    message.appendDecimal(count);
    message.append(" ");
    message.append(statusName(status));
  }

}
