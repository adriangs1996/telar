module telar.gui.features.notifications;

import std;
import telar.tbc;
import telar.base.text.utf8;

namespace telar::gui::features::notifications {

  namespace {

    // A duration as the separators write it: seconds below a minute, then minutes with two
    // digits of seconds, and hours with two digits of minutes past an hour.
    template <std::size_t Capacity>
    void appendDuration(BoundedText<Capacity>& text, std::uint32_t milliseconds) {
      constexpr std::uint32_t per_second = 1'000;
      constexpr std::uint32_t per_minute = 60;
      constexpr std::uint32_t per_hour = 60 * per_minute;
      constexpr std::uint32_t two_digits = 10;
      const auto seconds = milliseconds / per_second;
      const auto padded = [&](std::uint32_t value, bool pad) {
        if (pad && value < two_digits) {
          text.append("0");
        }

        text.appendDecimal(value);
      };

      if (seconds >= per_hour) {
        padded(seconds / per_hour, false);
        text.append("h ");
      }

      if (seconds >= per_minute) {
        padded(seconds % per_hour / per_minute, seconds >= per_hour);
        text.append("m ");
      }

      padded(seconds % per_minute, seconds >= per_minute);
      text.append("s");
    }

  }

  tbc::val_a<NotificationInput> CommandAlerts::input(const FinishedCommand& command, tbc::mut_a<Message> message) {
    // Room for " · ", the longest duration and the exit status.
    constexpr std::size_t trailer_bytes = 48;
    const auto first_line = command.command.substr(0, command.command.find('\n'));

    message.truncate(0);
    message.append(runtime::utf8Prefix(first_line, message_capacity - trailer_bytes));
    message.append(" · ");
    appendDuration(message, command.duration_ms);
    if (command.failed) {
      message.append(" · exit ");
      if (command.status < 0) {
        message.append("-");
      }

      message.appendDecimal(static_cast<std::uint32_t>(command.status < 0 ? -static_cast<std::int64_t>(command.status) : command.status));
    }

    return NotificationInput{
        .level = command.failed ? NotificationLevel::failure : NotificationLevel::success,
        .target = {.kind = NotificationTarget::Kind::pane, .id = command.pane_id},
        .title = command.failed ? std::string_view{"Command failed"} : std::string_view{"Command finished"},
        .message = message.view(),
    };
  }

}
