#pragma once

#include "application/notification_payload.hpp"
#include "command_line.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <cstddef>
#include <string_view>

namespace telar::gui::platform {

class AppleNotificationCommand {
public:
  AppleNotificationCommand() = default;
  ~AppleNotificationCommand() = default;
  AppleNotificationCommand(const AppleNotificationCommand &) = delete;
  AppleNotificationCommand &operator=(const AppleNotificationCommand &) = delete;
  AppleNotificationCommand(AppleNotificationCommand &&) = delete;
  AppleNotificationCommand &operator=(AppleNotificationCommand &&) = delete;

  [[nodiscard]] CommandLine prepare(const NotificationPayload &payload) {
    script_.truncate(0);
    script_.append(message_prefix);
    script_.append(payload.message.view());
    script_.append(title_prefix);
    script_.append(payload.title.view());
    script_.append(quote);

    return CommandLine::withArguments("/usr/bin/osascript", std::to_array<std::string_view>({"-e", script_.view()}));
  }

private:
  static constexpr std::string_view message_prefix = "display notification \"";
  static constexpr std::string_view title_prefix = "\" with title \"";
  static constexpr std::string_view quote = "\"";
  static constexpr std::size_t maximum_script_bytes = max_notification_title_bytes + max_notification_message_bytes + message_prefix.size() + title_prefix.size() + quote.size();

  BoundedText<maximum_script_bytes> script_;
};

struct LinuxNotificationCommand {
  [[nodiscard]] static CommandLine prepare(const NotificationPayload &payload) noexcept {
    return CommandLine::withArguments("notify-send", std::to_array<std::string_view>({"--", payload.title.view(), payload.message.view()}));
  }
};

#ifdef __APPLE__
using NativeNotificationCommand = AppleNotificationCommand;
#else
using NativeNotificationCommand = LinuxNotificationCommand;
#endif

}
