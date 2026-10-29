#pragma once

#include "command_process.hpp"
#include "host_command.hpp"
#include "platform/sound_commands.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <QProcess>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <exception>
#include <optional>
#include <stdexcept>

namespace telar::gui::qt {

struct NativeSoundHost {
  static constexpr auto timeout = std::chrono::seconds{3};
  static constexpr std::size_t attempts = platform::NativeSoundCommands::attempts;

  static void start(QProcess &process, platform::SoundAttempt request) {
    startHostCommand(process, platform::NativeSoundCommands::prepare(request));
  }
};

#ifndef TELAR_GUI_SOUND_HOST
#define TELAR_GUI_SOUND_HOST ::telar::gui::qt::NativeSoundHost
#endif

using ApplicationSoundHost = TELAR_GUI_SOUND_HOST;

template <typename Host>
concept SoundHost = CommandHost<Host, platform::SoundAttempt> && requires {
  { Host::attempts } -> std::convertible_to<std::size_t>;
};

template <typename Observer>
concept SoundObserver = requires(Observer &observer, std::optional<CommandFailure> failure) {
  { observer.soundPlaybackFinished(failure) } -> std::same_as<void>;
};

template <SoundHost Host, typename Observer>
class SoundPlayer {
public:
  explicit SoundPlayer(Observer &observer)
      : observer_(observer),
        process_(*this) {
    static_assert(SoundObserver<Observer>);
    static_assert(Host::attempts > 0);
  }

  void start(AgentSound sound) {
    if (process_.active()) {
      throw std::logic_error{"SoundPlaybackAlreadyActive"};
    }

    attempt_ = {.sound = sound};
    process_.start(attempt_);
  }

  [[nodiscard]] bool active() const noexcept {
    return process_.active();
  }

  void commandFinished(std::optional<CommandFailure> failure) {
    if (failure && attempt_.backend + 1 < Host::attempts) {
      ++attempt_.backend;
      try {
        process_.start(attempt_);
      } catch (const std::exception &) {
        observer_.soundPlaybackFinished(CommandFailure::launch);
      }

      return;
    }

    observer_.soundPlaybackFinished(failure);
  }

private:
  Observer &observer_;
  CommandProcess<Host, platform::SoundAttempt, SoundPlayer> process_;
  platform::SoundAttempt attempt_;
};

}
