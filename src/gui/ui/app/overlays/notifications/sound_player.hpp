#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/kit/process/command_process.hpp"
#include "ui/kit/process/host_command.hpp"
#include <QProcess>
#include <algorithm>
#include <array>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

#pragma once

#include "tbc/view.hpp"

import telar.gui.foundation.system;
import telar.base.ds;

namespace telar::gui::qt {

  struct NativeSoundHost {
    static constexpr auto timeout = std::chrono::seconds{3};
    static constexpr std::size_t attempts = system::NativeSoundCommands::attempts;

    static void start(QProcess& process, system::SoundAttempt request) {
      startHostCommand(process, system::NativeSoundCommands::prepare(request));
    }
  };

#ifndef TELAR_GUI_SOUND_HOST
#define TELAR_GUI_SOUND_HOST ::telar::gui::qt::NativeSoundHost
#endif

  using ApplicationSoundHost = TELAR_GUI_SOUND_HOST;

  template <typename Host>
  concept SoundHost = CommandHost<Host, system::SoundAttempt> && requires {
    { Host::attempts } -> std::convertible_to<std::size_t>;
  };

  template <typename Observer>
  concept SoundObserver = requires(Observer& observer, ds::Option<CommandFailure> failure) {
    { observer.soundPlaybackFinished(failure) } -> std::same_as<void>;
  };

  template <SoundHost Host, typename Observer>
  class SoundPlayer {
  public:
    explicit SoundPlayer(Observer& observer)
        : observer_(observer),
          process_(*this) {
      static_assert(SoundObserver<Observer>);
      static_assert(Host::attempts > 0);
    }

    ~SoundPlayer() = default;
    SoundPlayer(const SoundPlayer&) = delete;
    SoundPlayer& operator=(const SoundPlayer&) = delete;
    SoundPlayer(SoundPlayer&&) = delete;
    SoundPlayer& operator=(SoundPlayer&&) = delete;

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

    void commandFinished(ds::Option<CommandFailure> failure) {
      if (failure && attempt_.backend + 1 < Host::attempts) {
        ++attempt_.backend;
        try {
          process_.start(attempt_);
        } catch (const std::exception&) {
          observer_.soundPlaybackFinished(CommandFailure::launch);
        }

        return;
      }

      observer_.soundPlaybackFinished(failure);
    }

  private:
    Observer& observer_;
    // The process reports back to this player.
    tbc::val_self<CommandProcess<Host, system::SoundAttempt, SoundPlayer>> process_;
    system::SoundAttempt attempt_;
  };

}
