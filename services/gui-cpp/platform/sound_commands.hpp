#pragma once

#include "command_line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace telar::gui::platform {

struct SoundAttempt {
  AgentSound sound = AgentSound::ready;
  std::size_t backend = 0;
};

struct AppleSoundCommands {
  static constexpr std::size_t attempts = 1;

  [[nodiscard]] static CommandLine prepare(SoundAttempt request) {
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

  [[nodiscard]] static CommandLine prepare(SoundAttempt request) {
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
