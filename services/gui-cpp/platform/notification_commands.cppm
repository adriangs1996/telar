module;
#include <cstdio>
#include <unistd.h>

#include <cstddef>

#include <cstring>

#include <sys/un.h>

#include <cstdint>

#include <climits>
#include "tbc/view.hpp"

export module telar.gui.platform.notification_commands;

import std;

export import telar.gui.application.host_effects;

export import telar.gui.text.json_unsigned_integer;


export import telar.gui.core.unicode_scalar;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: platform/command_line.cppm
export {
namespace telar::gui::platform {

struct CommandLine {
  static constexpr std::size_t maximum_arguments = 5;

  std::string_view executable;
  std::array<std::string_view, maximum_arguments> values{};
  std::size_t count = 0;

  // The command views the executable and the texts the arguments view, region `a`.
  template <std::size_t Count>
  [[nodiscard]] static constexpr tbc::view<CommandLine, tbc::lt::a> withArguments(tbc::view<std::string_view, tbc::lt::a> executable, tbc::view<std::array<std::string_view, Count>, tbc::lt::a> arguments) noexcept {
    static_assert(Count <= maximum_arguments);
    CommandLine command{.executable = executable, .count = Count};
    std::copy(arguments.begin(), arguments.end(), command.values.begin());

    return command;
  }

  [[nodiscard]] inline std::span<const std::string_view> arguments() const noexcept {
    return std::span{values}.first(count);
  }
};

}
}

// Interface: platform/notification_commands.cppm
export {
namespace telar::gui::platform {

class AppleNotificationCommand {
public:
  AppleNotificationCommand() = default;
  ~AppleNotificationCommand() = default;
  AppleNotificationCommand(const AppleNotificationCommand &) = delete;
  AppleNotificationCommand &operator=(const AppleNotificationCommand &) = delete;
  AppleNotificationCommand(AppleNotificationCommand &&) = delete;
  AppleNotificationCommand &operator=(AppleNotificationCommand &&) = delete;

  [[nodiscard]] inline CommandLine prepare(const NotificationPayload &payload) {
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
  [[nodiscard]] inline static CommandLine prepare(const NotificationPayload &payload) noexcept {
    return CommandLine::withArguments("notify-send", std::to_array<std::string_view>({"--", payload.title.view(), payload.message.view()}));
  }
};

#ifdef __APPLE__
using NativeNotificationCommand = AppleNotificationCommand;
#else
using NativeNotificationCommand = LinuxNotificationCommand;
#endif

}
}

// Interface: platform/socket_limits.cppm
export {
namespace telar::gui::platform {

struct SocketLimits {
  static constexpr std::size_t path_bytes = sizeof(sockaddr_un{}.sun_path) - 1;
};

}
}

// Interface: platform/sound_commands.cppm
export {
namespace telar::gui::platform {

struct SoundAttempt {
  AgentSound sound = AgentSound::ready;
  std::size_t backend = 0;
};

struct AppleSoundCommands {
  static constexpr std::size_t attempts = 1;

  [[nodiscard]] inline static CommandLine prepare(SoundAttempt request) {
    if (request.backend >= attempts) {
      throw std::out_of_range{"SoundBackendOutOfRange"};
    }

    const std::string_view file = request.sound == AgentSound::ready ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Ping.aiff";

    return CommandLine::withArguments("/usr/bin/afplay", std::to_array<std::string_view>({file}));
  }
};

class LinuxSoundCommands {
public:
  static constexpr std::size_t attempts = 5;

  [[nodiscard]] inline static CommandLine prepare(SoundAttempt request) {
    const std::string_view file = request.sound == AgentSound::ready ? "/usr/share/sounds/freedesktop/stereo/complete.oga" : "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga";
    switch (backends.at(request.backend)) {
    case Backend::canberra:
      return CommandLine::withArguments("canberra-gtk-play", std::to_array<std::string_view>({"--id", request.sound == AgentSound::ready ? "complete" : "dialog-warning"}));
    case Backend::pulse:
      return CommandLine::withArguments("paplay", std::to_array<std::string_view>({file}));
    case Backend::pipewire:
      return CommandLine::withArguments("pw-play", std::to_array<std::string_view>({file}));
    case Backend::ffmpeg:
      return CommandLine::withArguments("ffplay", std::to_array<std::string_view>({"-nodisp", "-autoexit", "-loglevel", "quiet", file}));
    case Backend::mpv:
      return CommandLine::withArguments("mpv", std::to_array<std::string_view>({"--no-video", "--really-quiet", file}));
    }

    throw std::logic_error{"UnknownSoundBackend"};
  }

private:
  enum class Backend : std::uint8_t {
    canberra,
    pulse,
    pipewire,
    ffmpeg,
    mpv,
  };
  static constexpr std::array backends{Backend::canberra, Backend::pulse, Backend::pipewire, Backend::ffmpeg, Backend::mpv};
};

#ifdef __APPLE__
using NativeSoundCommands = AppleSoundCommands;
#else
using NativeSoundCommands = LinuxSoundCommands;
#endif

}
}

// Interface: platform/stdio_socket.cppm
export {
namespace telar::gui::platform {

struct StdioSocket {
  StdioSocket() = default;

  runtime::FileDescriptor local;
  runtime::FileDescriptor child;
};

[[nodiscard]] StdioSocket openStdioSocket();
[[nodiscard]] int bindStandardIo(int descriptor) noexcept;

}
}

// Interface: platform/wall_clock.cppm
export {
namespace telar::gui::platform {

struct WallClock {
  [[nodiscard]] static CalendarSample sample() noexcept;
};

}
}

// Interface: platform/window_lease.cppm
export {
namespace telar::gui::platform {

class WindowLease {
public:
  static constexpr unsigned maximum_windows = 64;

  explicit WindowLease(std::string_view endpoint);
  ~WindowLease();
  WindowLease(const WindowLease &) = delete;
  WindowLease &operator=(const WindowLease &) = delete;
  WindowLease(WindowLease &&) = delete;
  WindowLease &operator=(WindowLease &&) = delete;

  [[nodiscard]] unsigned slot() const noexcept;
  [[nodiscard]] std::string_view endpoint() const noexcept;

private:
  std::array<char, PATH_MAX> canonical_endpoint_{};
  std::size_t endpoint_length_ = 0;
  unsigned slot_ = 0;
  int descriptor_ = -1;
};

}
}
