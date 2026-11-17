// The agent sound playing and the one queued behind it. Nothing here is exported: only the
// feature's own units name it, through State.
export module telar.gui.features.notifications:playback;

import std;

import :sound;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::features::notifications {

  class SoundPlayback {
  public:
    explicit SoundPlayback(SoundPolicy configuration = {}) noexcept;

    [[nodiscard]] SoundPolicy configuration() const noexcept;

    [[nodiscard]] bool active() const noexcept;

    [[nodiscard]] std::optional<AgentSound> queued() const noexcept;

    [[nodiscard]] SoundRequestOutcome request(AgentSound kind) noexcept;

    [[nodiscard]] std::optional<AgentSound> complete();

    void schedulingFailed();

    void configure(SoundPolicy configuration) noexcept;

  private:
    [[nodiscard]] bool allows(AgentSound kind) const noexcept;

    SoundPolicy configuration_;
    std::optional<AgentSound> queued_;
    bool active_ = false;
  };

}
