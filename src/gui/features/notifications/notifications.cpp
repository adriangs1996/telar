module telar.gui.features.notifications;

import std;
import telar.base.diagnostics;
import telar.gui.foundation.core;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace telar::gui::features::notifications {

  void publish(State& state, NotificationInput input, std::uint64_t now_ns) {
    static_cast<void>(Access::center(state).push(now_ns, input));
    ++Access::revision(state);
  }

  bool advance(State& state, std::uint64_t now_ns) noexcept {
    if (!Access::center(state).advance(now_ns)) {
      return false;
    }

    ++Access::revision(state);

    return true;
  }

  bool dismiss(State& state, NotificationId id, std::uint64_t now_ns) noexcept {
    if (!Access::center(state).dismiss(id, now_ns)) {
      return false;
    }

    ++Access::revision(state);

    return true;
  }

  std::optional<NotificationTarget> activate(State& state, NotificationId id, std::uint64_t now_ns) noexcept {
    const auto target = Access::center(state).activate(id, now_ns);
    if (target) {
      ++Access::revision(state);
    }

    return target;
  }

  void configure(State& state, SoundPolicy policy) noexcept {
    Access::sound(state).configure(policy);
  }

  SoundRequestOutcome requestSound(State& state, AgentSound sound) noexcept {
    return Access::sound(state).request(sound);
  }

  std::optional<AgentSound> completeSound(State& state) {
    return Access::sound(state).complete();
  }

  void soundFailed(State& state) {
    Access::sound(state).schedulingFailed();
  }

  SoundStatus sound(const State& state) noexcept {
    const auto& playback = Access::sound(state);

    return {.playing = playback.active(), .queued = playback.queued()};
  }

  LimitRecorded record(State& state, LimitReach reach, LimitTime sampled) {
    return Access::limits(state).record(reach, sampled, 1);
  }

  std::optional<ReportLimit> takeReport(State& state, LimitSlot slot, std::int64_t awake_ms) {
    auto& limits = Access::limits(state);
    const auto hits = limits.takeReport(slot, awake_ms);
    if (!hits) {
      return std::nullopt;
    }

    return ReportLimit{.reach = limits.row(slot).reach(), .hits = *hits};
  }

  void restoreReport(State& state, LimitSlot slot, std::uint32_t hits) noexcept {
    Access::limits(state).restoreReport(slot, hits);
  }

  LimitNotices::Description describe(const State& state, LimitSlot slot) {
    const auto& row = Access::limits(state).row(slot);

    return LimitReports::describe(row.reach(), row.hits);
  }

}
