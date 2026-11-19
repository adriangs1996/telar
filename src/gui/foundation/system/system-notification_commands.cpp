module telar.gui.foundation.system;

import std;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

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

    return CommandLine::withArguments("/usr/bin/osascript", ds::Array<std::string_view, 2>{"-e", script_.view()});
  }

  CommandLine LinuxNotificationCommand::prepare(const NotificationPayload& payload) noexcept {
    return CommandLine::withArguments("notify-send", ds::Array<std::string_view, 3>{"--", payload.title.view(), payload.message.view()});
  }

  CommandLine AppleSoundCommands::prepare(SoundAttempt request) {
    if (request.backend >= attempts) {
      throw std::out_of_range{"SoundBackendOutOfRange"};
    }

    const std::string_view file = request.sound == AgentSound::ready ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Ping.aiff";

    return CommandLine::withArguments("/usr/bin/afplay", ds::Array<std::string_view, 1>{file});
  }

  CommandLine LinuxSoundCommands::prepare(SoundAttempt request) {
    const std::string_view file = request.sound == AgentSound::ready ? "/usr/share/sounds/freedesktop/stereo/complete.oga" : "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga";

    switch (backends.at(request.backend)) {
    case Backend::canberra:
      return CommandLine::withArguments("canberra-gtk-play", ds::Array<std::string_view, 2>{"--id", request.sound == AgentSound::ready ? "complete" : "dialog-warning"});
    case Backend::pulse:
      return CommandLine::withArguments("paplay", ds::Array<std::string_view, 1>{file});
    case Backend::pipewire:
      return CommandLine::withArguments("pw-play", ds::Array<std::string_view, 1>{file});
    case Backend::ffmpeg: {
      constexpr std::size_t ffplay_arguments = 5;

      return CommandLine::withArguments("ffplay", ds::Array<std::string_view, ffplay_arguments>{"-nodisp", "-autoexit", "-loglevel", "quiet", file});
    }
    case Backend::mpv:
      return CommandLine::withArguments("mpv", ds::Array<std::string_view, 3>{"--no-video", "--really-quiet", file});
    }

    throw std::logic_error{"UnknownSoundBackend"};
  }

}
