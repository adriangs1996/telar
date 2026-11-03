#include "agent_fixture.hpp"
#include "application/host_effects.hpp"
#include "application/notification_item.hpp"
#include "application/notification_payload.hpp"
#include "application/records.hpp"
#include "application/session.hpp"
#include "assertions.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/frame_pacer.hpp"
#include "session_fixture.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

struct Recorder {
  std::vector<NotificationPayload> notifications;
  std::vector<AgentSound> sounds;
  bool accept_sound = true;
  bool throw_notification = false;
};

struct Effects {
  Recorder &recorder;

  bool postNotification(const NotificationPayload &payload) {
    if (recorder.throw_notification) {
      throw std::runtime_error{"Injected notification admission failure"};
    }

    recorder.notifications.push_back(payload);

    return true;
  }

  bool playSound(AgentSound sound) {
    if (!recorder.accept_sound) {
      return false;
    }

    recorder.sounds.push_back(sound);

    return true;
  }
};

using Client = Session<SystemAllocator, Transport, platform::AwakeClock, Effects>;
static_assert(HostEffects<Effects> && std::is_empty_v<DiscardHostEffects>);

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
  std::array<Entry, capacity> entries;
  std::size_t count = 0;
};

struct InputEffects : DiscardHostEffects {
  Transport &transport;
  InputObservations &observations;

  InputEffects(Transport &output, InputObservations &recorded)
      : transport(output),
        observations(recorded) {}

  void notePaneInput(FramePacer::Pane pane, std::uint64_t now_ns) noexcept {
    if (observations.count == observations.entries.size()) {
      std::terminate();
    }

    observations.entries[observations.count++] = {.pane = pane, .at_ns = now_ns, .queued_inputs = transport.count(ClientTag::pane_input)};
  }
};

using InputClient = Session<SystemAllocator, Transport, InputClock, InputEffects>;
static_assert(PaneInputObserver<InputEffects> && !PaneInputObserver<DiscardHostEffects>);

void acceptedInputObservesTheQueuedPaneIdentity() {
  SystemAllocator memory;
  Transport transport;
  InputObservations observations;
  InputClient client{memory, transport, InputEffects{transport, observations}};
  openFirstPane(client, transport);
  const auto *pane = client.focusedPane();
  require(pane != nullptr, "input observation requires the opened pane");
  client.findPane(pane->id)->graphics.detach();
  require(pane->graphics.revision() != 0, "input observation must exercise a nonzero graphics revision");
  client.input(pane->id, "a");
  client.input(pane->id, "b", PaneInputSource::mouse);
  client.input(pane->id, "c", PaneInputSource::key_release);
  client.paste(pane->id, "d");
  constexpr std::size_t accepted_inputs = 4;
  require(observations.count == accepted_inputs, "keyboard, mouse, release and paste must observe accepted input");

  for (std::size_t index = 0; index < observations.count; ++index) {
    const auto &entry = observations.entries[index];
    require(entry.pane.pane_id == pane->id && entry.pane.attached && entry.pane.attachment_generation == pane->attachment_generation && entry.pane.frame_id == pane->screen.frameId(), "input grace must retain the actual frame and attachment identity");
    require(entry.pane.graphics_revision == pane->graphics.revision(), "input grace must retain the current graphics revision");
    require(entry.at_ns == InputClock::now_ns && entry.queued_inputs == index + 1, "the clock and observation must follow successful transport admission");
  }
}

void emptyRejectedAndProtocolInputDoNotGrantGrace() {
  SystemAllocator memory;
  Transport transport;
  InputObservations observations;
  InputClient client{memory, transport, InputEffects{transport, observations}};
  openFirstPane(client, transport);
  auto *pane = client.findPane(1);
  require(pane != nullptr, "input rejection requires the opened pane");
  client.input(pane->id, {});
  client.input(0, "missing");
  pane->attached = false;
  client.input(pane->id, "detached");
  pane->attached = true;
  pane->exited = true;
  client.input(pane->id, "exited");
  pane->exited = false;
  client.input(pane->id, "report", PaneInputSource::terminal_report);
  transport.reject_input_after = transport.count(ClientTag::pane_input);
  bool rejected = false;
  try {
    client.input(pane->id, "rejected");
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && observations.count == 0, "empty, unavailable, protocol and refused input must not grant grace");
}

void acceptedPrefixRetainsItsGraceWhenTheNextChunkFails() {
  SystemAllocator memory;
  Transport transport;
  InputObservations observations;
  InputClient client{memory, transport, InputEffects{transport, observations}};
  openFirstPane(client, transport);
  transport.reject_input_after = transport.count(ClientTag::pane_input) + 1;
  const std::string input(InputClient::input_chunk_size + 1, 'x');
  bool rejected = false;
  try {
    client.input(1, input);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && observations.count == 1 && observations.entries.front().queued_inputs == 1, "a later chunk failure must retain the accepted prefix's input grace");
}

void absentObserverDoesNotReadTheClock() {
  SystemAllocator memory;
  Transport transport;
  Session<SystemAllocator, Transport, InputClock> client{memory, transport};
  openFirstPane(client, transport);
  const auto previous_reads = InputClock::reads;
  client.input(1, "without observer");
  require(InputClock::reads == previous_reads, "an absent input observer must compile out clock sampling");
}

void systemDeliveryKeepsEveryPublicationAndDoesNotReplaceTheCenter() {
  SystemAllocator memory;
  Transport transport;
  Recorder recorder;
  Client client{memory, transport, Effects{recorder}};
  client.publishNotification({.title = "Local only", .message = "body", .link = {}});
  require(recorder.notifications.empty() && client.notifications().items().size() == 1, "default delivery must retain a card without contacting the desktop");

  Configuration configuration;
  configuration.notification_delivery = NotificationDelivery::system;
  client.configure(configuration);
  const NotificationInput input{.title = "--help\n\"quoted\"\\end", .message = "body\t\"quoted\"\\end", .link = {}};
  client.publishNotification(input);
  client.publishNotification(input);
  require(recorder.notifications.size() == 2, "desktop delivery must retain duplicate publications even when the center coalesces them");
  require(recorder.notifications.front().title.view() == "--helpquotedend" && recorder.notifications.front().message.view() == "bodyquotedend", "desktop payloads must remove the original controls, quotes and backslashes");
  require(client.notifications().items().size() == 2 && client.notifications().items().front().title.view() == input.title, "desktop sanitization must not replace the original card text");

  recorder.throw_notification = true;
  client.publishNotification({.title = "Still visible", .message = "admission failed", .link = {}});
  require(client.notifications().items().front().title.view() == "Still visible", "optional desktop admission failure must not prevent in-app publication");
}

void wireDeliveryAndCommittedAgentAlertsUseTheSameHostBoundary() {
  SystemAllocator memory;
  Transport transport;
  Recorder recorder;
  Client client{memory, transport, Effects{recorder}};
  Configuration configuration;
  configuration.notification_delivery = NotificationDelivery::system;
  client.configure(configuration);
  Notification notice;
  notice.title = "Runtime notice";
  notice.message = "body";
  deliver(client, notice);
  require(recorder.notifications.size() == 1 && recorder.notifications.front().title.view() == "Runtime notice", "wire notifications must reach the configured host once");

  std::array agents{agentSnapshotEntry()};
  agents.front().status = AgentStatus::working;
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(recorder.notifications.size() == 1, "initial agent discovery must not deliver a host alert");

  agents.front().status = AgentStatus::blocked;
  deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
  require(recorder.notifications.size() == 2, "a committed agent attention transition must deliver a host alert");
  deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(recorder.notifications.size() == 2, "duplicate and stale agent snapshots must not deliver another host alert");
}

void soundsRequireExactAgentIdentityAndCoalesceThroughCompletion() {
  SystemAllocator memory;
  Transport transport;
  Recorder recorder;
  Client client{memory, transport, Effects{recorder}};
  const std::array agents{agentSnapshotEntry()};
  const auto &agent = agents.front();
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  const AgentSoundNotification ready{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .sound = AgentSound::ready};
  auto stale = ready;
  ++stale.pane_generation;
  deliver(client, stale);
  auto missing = ready;
  ++missing.pane_id;
  deliver(client, missing);
  require(recorder.sounds.empty(), "unknown panes and stale generations must not start host playback");

  deliver(client, ready);
  deliver(client, ready);
  auto attention = ready;
  attention.sound = AgentSound::needs_input;
  deliver(client, attention);
  deliver(client, ready);
  require(recorder.sounds == std::vector{AgentSound::ready}, "one active sound must keep later requests off the host");

  client.completeAgentSound();
  require(recorder.sounds == std::vector{AgentSound::ready, AgentSound::needs_input}, "attention must dominate the coalesced successor");
  client.completeAgentSound();
  deliver(client, ready);
  require(recorder.sounds == std::vector{AgentSound::ready, AgentSound::needs_input, AgentSound::ready}, "completion must release admission for a later sound");
  client.completeAgentSound();
}

void policyReloadAndAdmissionFailureDoNotLeavePlaybackReserved() {
  SystemAllocator memory;
  Transport transport;
  Recorder recorder;
  Client client{memory, transport, Effects{recorder}};
  const std::array agents{agentSnapshotEntry()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  const auto &agent = agents.front();
  const AgentSoundNotification ready{.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .sound = AgentSound::ready};
  recorder.accept_sound = false;
  deliver(client, ready);
  recorder.accept_sound = true;
  deliver(client, ready);
  require(recorder.sounds.size() == 1, "failed scheduling must release the active reservation");
  deliver(client, ready);

  Configuration configuration;
  configuration.sound.enabled = false;
  client.configure(configuration);
  client.completeAgentSound();
  deliver(client, ready);
  require(recorder.sounds.size() == 1, "policy reload must discard a now-disabled successor and reject new requests");

  configuration.sound.enabled = true;
  client.configure(configuration);
  deliver(client, ready);
  require(recorder.sounds.size() == 2, "re-enabling audio must permit a fresh sound");
  client.completeAgentSound();
}

}

int main() try {
  acceptedInputObservesTheQueuedPaneIdentity();
  emptyRejectedAndProtocolInputDoNotGrantGrace();
  acceptedPrefixRetainsItsGraceWhenTheNextChunkFails();
  absentObserverDoesNotReadTheClock();
  systemDeliveryKeepsEveryPublicationAndDoesNotReplaceTheCenter();
  wireDeliveryAndCommittedAgentAlertsUseTheSameHostBoundary();
  soundsRequireExactAgentIdentityAndCoalesceThroughCompletion();
  policyReloadAndAdmissionFailureDoNotLeavePlaybackReserved();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
