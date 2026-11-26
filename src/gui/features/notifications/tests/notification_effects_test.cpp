#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.features.notifications;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;

  // The agent sounds through the notifications' use cases, under the names the assertions read.
  class Playback {
  public:
    features::notifications::SoundRequestOutcome request(AgentSound sound) noexcept {
      return features::notifications::requestSound(state_, sound);
    }

    ds::Option<AgentSound> complete() {
      return features::notifications::completeSound(state_);
    }

    void schedulingFailed() {
      features::notifications::soundFailed(state_);
    }

    void configure(SoundPolicy policy) noexcept {
      features::notifications::configure(state_, policy);
    }

    [[nodiscard]] bool active() const noexcept {
      return features::notifications::sound(state_).playing;
    }

    [[nodiscard]] ds::Option<AgentSound> queued() const noexcept {
      return features::notifications::sound(state_).queued;
    }

  private:
    features::notifications::State state_;
  };

  void soundsCoalesceIntoOnePrioritizedSuccessor() {
    Playback playback;

    check(playback.request(AgentSound::ready).state == features::notifications::SoundRequestOutcome::State::start && playback.active(), "an idle permitted sound must reserve one worker");
    check(playback.request(AgentSound::ready).state == features::notifications::SoundRequestOutcome::State::queued, "an active worker must retain one successor");
    check(playback.request(AgentSound::needs_input).state == features::notifications::SoundRequestOutcome::State::queued, "input attention must coalesce with queued completion sounds");
    static_cast<void>(playback.request(AgentSound::ready));
    check(playback.queued() == AgentSound::needs_input, "later completion sounds must not replace pending input attention");
    check(playback.complete() == AgentSound::needs_input && playback.active() && !playback.queued(), "completion must transfer its reservation to the coalesced successor");
    check(!playback.complete() && !playback.active(), "an empty queue must release the worker");
  }

  void policyChangesLeaveRunningWorkAndRemoveDisallowedSuccessors() {
    Playback playback;

    static_cast<void>(playback.request(AgentSound::ready));
    static_cast<void>(playback.request(AgentSound::needs_input));
    playback.configure({.needs_input = false});
    check(playback.active() && !playback.queued(), "reconfiguration must remove only disallowed queued work");
    check(playback.request(AgentSound::needs_input).state == features::notifications::SoundRequestOutcome::State::ignored, "disabled sound kinds must not reserve a successor");
    check(!playback.complete() && !playback.active(), "a removed successor must not start after the active command ends");
    static_cast<void>(playback.request(AgentSound::ready));
    playback.schedulingFailed();
    check(!playback.active() && playback.request(AgentSound::ready).state == features::notifications::SoundRequestOutcome::State::start, "a failed background schedule must release its reservation for retry");
    playback.configure({.enabled = false});
    check(playback.active() && playback.request(AgentSound::ready).state == features::notifications::SoundRequestOutcome::State::ignored, "global disabling must let existing work finish without admitting new work");
    static_cast<void>(playback.complete());
  }

  const telar::testing::Case case_sounds_coalesce_into_one_prioritized_successor{"notification_effects.sounds_coalesce_into_one_prioritized_successor", soundsCoalesceIntoOnePrioritizedSuccessor};
  const telar::testing::Case case_policy_changes_leave_running_work_and_remove_disallowed_successors{"notification_effects.policy_changes_leave_running_work_and_remove_disallowed_successors", policyChangesLeaveRunningWorkAndRemoveDisallowedSuccessors};

}
