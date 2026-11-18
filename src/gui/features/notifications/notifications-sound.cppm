// What asking for an agent's sound did: nothing, queued it behind the one playing, or started it;
// and what plays and waits.
export module telar.gui.features.notifications:sound;

import std;

import telar.wire.vocabulary;
import telar.base.ds;

// Interface: application/sound_playback.cppm
export {
  namespace telar::gui::features::notifications {

    struct SoundRequestOutcome {
      enum class State : std::uint8_t {
        ignored,
        queued,
        start,
      };

      State state = State::ignored;
      AgentSound sound = AgentSound::ready;
    };

    // The agent sound playing, if any, and the one queued to follow it.
    struct SoundStatus {
      bool playing = false;
      ds::Option<AgentSound> queued = ds::none;
    };

  }
}
