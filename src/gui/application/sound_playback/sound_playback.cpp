module telar.gui.application.sound_playback;

import std;

namespace telar::gui {

  SoundPlayback::SoundPlayback(SoundPolicy configuration) noexcept
      : configuration_(configuration) {}

  SoundPolicy SoundPlayback::configuration() const noexcept {
    return configuration_;
  }

  bool SoundPlayback::active() const noexcept {
    return active_;
  }

  std::optional<AgentSound> SoundPlayback::queued() const noexcept {
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

  std::optional<AgentSound> SoundPlayback::complete() {
    if (!active_) {
      throw std::logic_error{"NoActiveSoundPlayback"};
    }

    active_ = false;
    const auto next = std::exchange(queued_, std::nullopt);
    if (!next || !allows(*next)) {
      return std::nullopt;
    }

    active_ = true;

    return next;
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
