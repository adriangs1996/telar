module;

// The notices the user sees: the notification center and its cards, the alerts agents raise,
// the sounds they play and the limits the session reached.
export module telar.gui.features.notifications;

export import :alerts;
export import :center;
export import :limits;
export import :sound;
export import :stack;
export import :text;
// Exported as every interface partition must be; they export nothing.
export import :limit_reports;
export import :playback;

import std;

import telar.base.diagnostics;
import telar.gui.foundation.core;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::notifications {

  struct Access;

}

export namespace telar::gui::features::notifications {

  // The notices shown and how often they changed, the agent sound playing and the one queued,
  // and the limits the session reached. Opaque: only the use cases below reach it.
  class State {
    friend struct Access;

    NotificationCenter center_;
    std::uint64_t revision_ = 0;
    SoundPlayback sound_;
    LimitReports limits_;
  };

  // ---- notices ------------------------------------------------------------------------------

  // Shows `input` from `now_ns`, the oldest notice giving way when the center is full.
  void publish(State& state, NotificationInput input, std::uint64_t now_ns);

  // Moves the notices' fades and expiries to `now_ns`; true when any changed.
  [[nodiscard]] bool advance(State& state, std::uint64_t now_ns) noexcept;

  // Fades notice `id` out; false when it is gone or already leaving.
  [[nodiscard]] bool dismiss(State& state, NotificationId id, std::uint64_t now_ns) noexcept;

  // The user chose notice `id`: it fades out, and what it points at is for the caller to show.
  [[nodiscard]] ds::Option<NotificationTarget> activate(State& state, NotificationId id, std::uint64_t now_ns) noexcept;

  // What the window paints: the notices, valid until a use case changes them.
  [[nodiscard]] [[tbc::hot_path]] inline const NotificationCenter& center(const State& state) noexcept;

  // Changes whenever the notices do.
  [[nodiscard]] [[tbc::hot_path]] inline std::uint64_t revision(const State& state) noexcept;

  // ---- agent sounds -------------------------------------------------------------------------

  // Which sounds play; a queued one the policy no longer allows is dropped.
  void configure(State& state, SoundPolicy policy) noexcept;

  // An agent asked for `sound`: start it, queue it behind the one playing, or ignore it.
  [[nodiscard]] SoundRequestOutcome requestSound(State& state, AgentSound sound) noexcept;

  // The playing sound ended: the queued one, if any, starts. Throws when none was playing.
  [[nodiscard]] ds::Option<AgentSound> completeSound(State& state);

  // The host could not start the sound that was to play.
  void soundFailed(State& state);

  [[nodiscard]] SoundStatus sound(const State& state) noexcept;

  // ---- reached limits -----------------------------------------------------------------------

  // Counts a reach of `reach`'s limit at `sampled`.
  [[nodiscard]] LimitRecorded record(State& state, LimitReach reach, LimitTime sampled);

  // The report the runtime is due for the limit in `slot`, its hits since the last one; none
  // until the report interval passed. The reach views the state until it changes.
  [[nodiscard]] ds::Option<ReportLimit> takeReport(State& state, LimitSlot slot, std::int64_t awake_ms);

  // The report the transport refused: its hits count again for the next one.
  void restoreReport(State& state, LimitSlot slot, std::uint32_t hits) noexcept;

  // What the notice of the limit in `slot` says: the limit, the request and how often.
  [[nodiscard]] LimitNotices::Description describe(const State& state, LimitSlot slot);

}

namespace telar::gui::features::notifications {

  struct Access {
    [[nodiscard]] static constexpr NotificationCenter& center(State& state) noexcept {
      return state.center_;
    }

    [[nodiscard]] static constexpr const NotificationCenter& center(const State& state) noexcept {
      return state.center_;
    }

    [[nodiscard]] static constexpr std::uint64_t& revision(State& state) noexcept {
      return state.revision_;
    }

    [[nodiscard]] static constexpr std::uint64_t revision(const State& state) noexcept {
      return state.revision_;
    }

    [[nodiscard]] static constexpr SoundPlayback& sound(State& state) noexcept {
      return state.sound_;
    }

    [[nodiscard]] static constexpr const SoundPlayback& sound(const State& state) noexcept {
      return state.sound_;
    }

    [[nodiscard]] static constexpr LimitReports& limits(State& state) noexcept {
      return state.limits_;
    }

    [[nodiscard]] static constexpr const LimitReports& limits(const State& state) noexcept {
      return state.limits_;
    }
  };

  inline const NotificationCenter& center(const State& state) noexcept {
    return Access::center(state);
  }

  inline std::uint64_t revision(const State& state) noexcept {
    return Access::revision(state);
  }

}
