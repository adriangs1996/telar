module telar.gui.features.notifications;

import std;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::notifications {

  SoundPlayback::SoundPlayback(SoundPolicy configuration) noexcept
      : configuration_(configuration) {}

  SoundPolicy SoundPlayback::configuration() const noexcept {
    return configuration_;
  }

  bool SoundPlayback::active() const noexcept {
    return active_;
  }

  ds::Option<AgentSound> SoundPlayback::queued() const noexcept {
    return queued_;
  }

  SoundRequestOutcome SoundPlayback::request(AgentSound kind) noexcept {
    if (!allows(kind)) {
      return {};
    }

    if (active_) {
      queued_ = queued_ == AgentSound::needs_input || kind == AgentSound::needs_input ? AgentSound::needs_input : AgentSound::ready;

      return {.state = SoundRequestOutcome::State::queued};
    }

    active_ = true;

    return {.state = SoundRequestOutcome::State::start, .sound = kind};
  }

  ds::Option<AgentSound> SoundPlayback::complete() {
    if (!active_) {
      throw std::logic_error{"NoActiveSoundPlayback"};
    }

    active_ = false;
    const auto next = std::exchange(queued_, ds::none);
    if (!next || !allows(*next)) {
      return ds::none;
    }

    active_ = true;

    return *next;
  }

  void SoundPlayback::schedulingFailed() {
    if (!active_ || queued_) {
      throw std::logic_error{"InvalidSoundSchedulingFailure"};
    }

    active_ = false;
  }

  void SoundPlayback::configure(SoundPolicy configuration) noexcept {
    configuration_ = configuration;
    if (queued_ && !allows(*queued_)) {
      queued_.reset();
    }
  }

  bool SoundPlayback::allows(AgentSound kind) const noexcept {
    if (!configuration_.enabled) {
      return false;
    }

    switch (kind) {
    case AgentSound::ready:
      return configuration_.ready;
    case AgentSound::needs_input:
      return configuration_.needs_input;
    }

    return false;
  }

}
