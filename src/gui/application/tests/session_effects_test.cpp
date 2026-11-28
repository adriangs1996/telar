#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

import telar.testing;
import telar.gui.tests.agent_fixture;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.gui.features.notifications;
import telar.wire.agents;
import telar.gui.features.window;
import telar.base.ds;
import telar.wire.clients;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;
  using namespace telar::gui::features::window;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;

  struct Recorder {
    std::vector<NotificationPayload> notifications;
    std::vector<AgentSound> sounds;
    bool accept_sound = true;
    bool throw_notification = false;
  };

  struct Effects final : application::HostEffects {
    explicit Effects(Recorder& recorded)
        : recorder(recorded) {}

    Recorder& recorder;

    bool postNotification(const NotificationPayload& payload) override {
      if (recorder.throw_notification) {
        throw std::runtime_error{"Injected notification admission failure"};
      }

      recorder.notifications.push_back(payload);

      return true;
    }

    bool playSound(AgentSound sound) override {
      if (!recorder.accept_sound) {
        return false;
      }

      recorder.sounds.push_back(sound);

      return true;
    }
  };

  struct InputClock {
    static inline std::uint64_t now_ns = FramePacer::nanoseconds_per_second;
    static inline std::size_t reads = 0;

    static std::uint64_t nowNanoseconds() noexcept {
      ++reads;

      return now_ns;
    }
  };

  struct InputObservations {
    struct Entry {
      FramePacer::Pane pane;
      std::uint64_t at_ns = 0;
      std::size_t queued_inputs = 0;
    };

    static constexpr std::size_t capacity = 16;
    ds::Array<Entry, capacity> entries;
    std::size_t count = 0;
  };

  struct InputEffects final : application::DiscardHostEffects {
    Transport& transport;
    InputObservations& observations;

    InputEffects(Transport& output, InputObservations& recorded)
        : transport(output),
          observations(recorded) {}

    void notePaneInput(FramePacer::Pane pane) noexcept override {
      if (observations.count == observations.entries.size()) {
        std::terminate();
      }

      observations.entries.atMut(observations.count++) = {.pane = pane, .at_ns = InputClock::nowNanoseconds(), .queued_inputs = transport.count(ClientTag::pane_input)};
    }
  };

  void acceptedInputObservesTheQueuedPaneIdentity() {
    SystemAllocator memory;
    Transport transport;
    InputObservations observations;
    InputEffects effects{transport, observations};
    TestSession client{memory, transport, effects, &InputClock::nowNanoseconds};

    openFirstPane(client, transport);
    const auto* pane = client.focusedPaneMut();

    check(pane != nullptr, "input observation requires the opened pane");
    client.findPaneMut(pane->id)->graphics.detach();
    check(pane->graphics.revision() != 0, "input observation must exercise a nonzero graphics revision");
    client.input(pane->id, "a");
    client.input(pane->id, "b", application::PaneInputSource::mouse);
    client.input(pane->id, "c", application::PaneInputSource::key_release);
    client.paste(pane->id, "d");
    constexpr std::size_t accepted_inputs = 4;

    check(observations.count == accepted_inputs, "keyboard, mouse, release and paste must observe accepted input");

    for (std::size_t index = 0; index < observations.count; ++index) {
      const auto& entry = observations.entries[index];

      check(entry.pane.pane_id == pane->id && entry.pane.attached && entry.pane.attachment_generation == pane->attachment_generation && entry.pane.frame_id == pane->screen.frameId(), "input grace must retain the actual frame and attachment identity");
      check(entry.pane.graphics_revision == pane->graphics.revision(), "input grace must retain the current graphics revision");
      check(entry.at_ns == InputClock::now_ns && entry.queued_inputs == index + 1, "the clock and observation must follow successful transport admission");
    }
  }

  void emptyRejectedAndProtocolInputDoNotGrantGrace() {
    SystemAllocator memory;
    Transport transport;
    InputObservations observations;
    InputEffects effects{transport, observations};
    TestSession client{memory, transport, effects, &InputClock::nowNanoseconds};

    openFirstPane(client, transport);
    auto* pane = client.findPaneMut(1);

    check(pane != nullptr, "input rejection requires the opened pane");
    client.input(pane->id, {});
    client.input(0, "missing");
    pane->attached = false;
    client.input(pane->id, "detached");
    pane->attached = true;
    pane->exited = true;
    client.input(pane->id, "exited");
    pane->exited = false;
    client.input(pane->id, "report", application::PaneInputSource::terminal_report);
    transport.reject_input_after = transport.count(ClientTag::pane_input);
    bool rejected = false;

    try {
      client.input(pane->id, "rejected");
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && observations.count == 0, "empty, unavailable, protocol and refused input must not grant grace");
  }

  void acceptedPrefixRetainsItsGraceWhenTheNextChunkFails() {
    SystemAllocator memory;
    Transport transport;
    InputObservations observations;
    InputEffects effects{transport, observations};
    TestSession client{memory, transport, effects, &InputClock::nowNanoseconds};

    openFirstPane(client, transport);
    transport.reject_input_after = transport.count(ClientTag::pane_input) + 1;
    const std::string input(application::Session::input_chunk_size + 1, 'x');
    bool rejected = false;

    try {
      client.input(1, input);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && observations.count == 1 && observations.entries.front().queued_inputs == 1, "a later chunk failure must retain the accepted prefix's input grace");
  }

  void absentObserverDoesNotReadTheClock() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport, &InputClock::nowNanoseconds};

    openFirstPane(client, transport);
    const auto previous_reads = InputClock::reads;

    client.input(1, "without observer");
    check(InputClock::reads == previous_reads, "an absent input observer must not read the clock");
  }

  void systemDeliveryKeepsEveryPublicationAndDoesNotReplaceTheCenter() {
    SystemAllocator memory;
    Transport transport;
    Recorder recorder;
    Effects effects{recorder};
    TestSession client{memory, transport, effects};

    application::notifications::publish(client, {.title = "Local only", .message = "body", .link = {}});
    check(recorder.notifications.empty() && application::notifications::center(client).items().size() == 1, "default delivery must retain a card without contacting the desktop");

    Configuration configuration;

    configuration.notification_delivery = NotificationDelivery::system;
    application::configuration::configure(client, configuration);
    const NotificationInput input{.title = "--help\n\"quoted\"\\end", .message = "body\t\"quoted\"\\end", .link = {}};

    application::notifications::publish(client, input);
    application::notifications::publish(client, input);
    check(recorder.notifications.size() == 2, "desktop delivery must retain duplicate publications even when the center coalesces them");
    check(recorder.notifications.front().title.view() == "--helpquotedend" && recorder.notifications.front().message.view() == "bodyquotedend", "desktop payloads must remove the original controls, quotes and backslashes");
    check(application::notifications::center(client).items().size() == 2 && application::notifications::center(client).items().front().title.view() == input.title, "desktop sanitization must not replace the original card text");

    recorder.throw_notification = true;
    application::notifications::publish(client, {.title = "Still visible", .message = "admission failed", .link = {}});
    check(application::notifications::center(client).items().front().title.view() == "Still visible", "optional desktop admission failure must not prevent in-app publication");
  }

  void wireDeliveryAndCommittedAgentAlertsUseTheSameHostBoundary() {
    SystemAllocator memory;
    Transport transport;
    Recorder recorder;
    Effects effects{recorder};
    TestSession client{memory, transport, effects};
    Configuration configuration;

    configuration.notification_delivery = NotificationDelivery::system;
    application::configuration::configure(client, configuration);
    Notification notice;

    notice.title = "Runtime notice";
    notice.message = "body";
    deliver(client, notice);
    check(recorder.notifications.size() == 1 && recorder.notifications.front().title.view() == "Runtime notice", "wire notifications must reach the configured host once");

    ds::Array agents{agentSnapshotEntry()};

    agents.atMut(0).status = AgentStatus::working;
    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(recorder.notifications.size() == 1, "initial agent discovery must not deliver a host alert");

    agents.atMut(0).status = AgentStatus::blocked;
    deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
    check(recorder.notifications.size() == 2, "a committed agent attention transition must deliver a host alert");
    deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(recorder.notifications.size() == 2, "duplicate and stale agent snapshots must not deliver another host alert");
  }

  void soundsRequireExactAgentIdentityAndCoalesceThroughCompletion() {
    SystemAllocator memory;
    Transport transport;
    Recorder recorder;
    Effects effects{recorder};
    TestSession client{memory, transport, effects};
    const ds::Array agents{agentSnapshotEntry()};
    const auto& agent = agents.front();

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    const AgentSoundNotification ready{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .sound = AgentSound::ready};
    auto stale = ready;

    ++stale.pane_generation;
    deliver(client, stale);
    auto missing = ready;

    ++missing.pane_id;
    deliver(client, missing);
    check(recorder.sounds.empty(), "unknown panes and stale generations must not start host playback");

    deliver(client, ready);
    deliver(client, ready);
    auto attention = ready;

    attention.sound = AgentSound::needs_input;
    deliver(client, attention);
    deliver(client, ready);
    check(recorder.sounds == std::vector{AgentSound::ready}, "one active sound must keep later requests off the host");

    application::notifications::completeSound(client);
    check(recorder.sounds == std::vector{AgentSound::ready, AgentSound::needs_input}, "attention must dominate the coalesced successor");
    application::notifications::completeSound(client);
    deliver(client, ready);
    check(recorder.sounds == std::vector{AgentSound::ready, AgentSound::needs_input, AgentSound::ready}, "completion must release admission for a later sound");
    application::notifications::completeSound(client);
  }

  void policyReloadAndAdmissionFailureDoNotLeavePlaybackReserved() {
    SystemAllocator memory;
    Transport transport;
    Recorder recorder;
    Effects effects{recorder};
    TestSession client{memory, transport, effects};
    const ds::Array agents{agentSnapshotEntry()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    const auto& agent = agents.front();
    const AgentSoundNotification ready{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .sound = AgentSound::ready};

    recorder.accept_sound = false;
    deliver(client, ready);
    recorder.accept_sound = true;
    deliver(client, ready);
    check(recorder.sounds.size() == 1, "failed scheduling must release the active reservation");
    deliver(client, ready);

    Configuration configuration;

    configuration.sound.enabled = false;
    application::configuration::configure(client, configuration);
    application::notifications::completeSound(client);
    deliver(client, ready);
    check(recorder.sounds.size() == 1, "policy reload must discard a now-disabled successor and reject new requests");

    configuration.sound.enabled = true;
    application::configuration::configure(client, configuration);
    deliver(client, ready);
    check(recorder.sounds.size() == 2, "re-enabling audio must permit a fresh sound");
    application::notifications::completeSound(client);
  }

  const telar::testing::Case case_accepted_input_observes_the_queued_pane_identity{"session_effects.accepted_input_observes_the_queued_pane_identity", acceptedInputObservesTheQueuedPaneIdentity};
  const telar::testing::Case case_empty_rejected_and_protocol_input_do_not_grant_grace{"session_effects.empty_rejected_and_protocol_input_do_not_grant_grace", emptyRejectedAndProtocolInputDoNotGrantGrace};
  const telar::testing::Case case_accepted_prefix_retains_its_grace_when_the_next_chunk_fails{"session_effects.accepted_prefix_retains_its_grace_when_the_next_chunk_fails", acceptedPrefixRetainsItsGraceWhenTheNextChunkFails};
  const telar::testing::Case case_absent_observer_does_not_read_the_clock{"session_effects.absent_observer_does_not_read_the_clock", absentObserverDoesNotReadTheClock};
  const telar::testing::Case case_system_delivery_keeps_every_publication_and_does_not_replace_the_center{"session_effects.system_delivery_keeps_every_publication_and_does_not_replace_the_center", systemDeliveryKeepsEveryPublicationAndDoesNotReplaceTheCenter};
  const telar::testing::Case case_wire_delivery_and_committed_agent_alerts_use_the_same_host_boundary{"session_effects.wire_delivery_and_committed_agent_alerts_use_the_same_host_boundary", wireDeliveryAndCommittedAgentAlertsUseTheSameHostBoundary};
  const telar::testing::Case case_sounds_require_exact_agent_identity_and_coalesce_through_completion{"session_effects.sounds_require_exact_agent_identity_and_coalesce_through_completion", soundsRequireExactAgentIdentityAndCoalesceThroughCompletion};
  const telar::testing::Case case_policy_reload_and_admission_failure_do_not_leave_playback_reserved{"session_effects.policy_reload_and_admission_failure_do_not_leave_playback_reserved", policyReloadAndAdmissionFailureDoNotLeavePlaybackReserved};

}
