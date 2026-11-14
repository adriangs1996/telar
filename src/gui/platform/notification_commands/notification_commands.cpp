module telar.gui.platform.notification_commands;

import std;

namespace telar::gui::platform {

  std::span<const std::string_view> CommandLine::arguments() const noexcept {
    return std::span{values}.first(count);
  }

  CommandLine AppleNotificationCommand::prepare(const NotificationPayload& payload) {
    script_.truncate(0);
    script_.append(message_prefix);
    script_.append(payload.message.view());
    script_.append(title_prefix);
    script_.append(payload.title.view());
    script_.append(quote);

    return CommandLine::withArguments("/usr/bin/osascript", std::to_array<std::string_view>({"-e", script_.view()}));
  }

  CommandLine LinuxNotificationCommand::prepare(const NotificationPayload& payload) noexcept {
    return CommandLine::withArguments("notify-send", std::to_array<std::string_view>({"--", payload.title.view(), payload.message.view()}));
  }

  CommandLine AppleSoundCommands::prepare(SoundAttempt request) {
    if (request.backend >= attempts) {
      throw std::out_of_range{"SoundBackendOutOfRange"};
    }

    const std::string_view file = request.sound == AgentSound::ready ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Ping.aiff";

    return CommandLine::withArguments("/usr/bin/afplay", std::to_array<std::string_view>({file}));
  }

  CommandLine LinuxSoundCommands::prepare(SoundAttempt request) {
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

}
