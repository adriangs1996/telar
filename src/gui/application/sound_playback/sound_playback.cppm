export module telar.gui.application.sound_playback;

import std;

import telar.gui.core.metrics;
import telar.wire.vocabulary;

// Interface: application/sound_playback.cppm
export {
  namespace telar::gui {

    struct SoundRequestOutcome {
      enum class State : std::uint8_t {
        ignored,
        queued,
        start,
      };

      State state = State::ignored;
      AgentSound sound = AgentSound::ready;
    };

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
}
