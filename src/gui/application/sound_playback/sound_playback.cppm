export module telar.gui.application.sound_playback;

import std;

export import telar.gui.core.metrics;
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
      inline explicit SoundPlayback(SoundPolicy configuration = {}) noexcept
          : configuration_(configuration) {}

      [[nodiscard]] inline SoundPolicy configuration() const noexcept {
        return configuration_;
      }

      [[nodiscard]] inline bool active() const noexcept {
        return active_;
      }

      [[nodiscard]] inline std::optional<AgentSound> queued() const noexcept {
        return queued_;
      }

      [[nodiscard]] inline SoundRequestOutcome request(AgentSound kind) noexcept {
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

      [[nodiscard]] inline std::optional<AgentSound> complete() {
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

      inline void schedulingFailed() {
        if (!active_ || queued_) {
          throw std::logic_error{"InvalidSoundSchedulingFailure"};
        }

        active_ = false;
      }

      inline void configure(SoundPolicy configuration) noexcept {
        configuration_ = configuration;
        if (queued_ && !allows(*queued_)) {
          queued_.reset();
        }
      }

    private:
      [[nodiscard]] inline bool allows(AgentSound kind) const noexcept {
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

      SoundPolicy configuration_;
      std::optional<AgentSound> queued_;
      bool active_ = false;
    };

  }
}
