#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "telar_client/serializers/telar_cells.hpp"
#include <cstdint>
#include <optional>
#include <algorithm>
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/serializers/telar_protocol.hpp"
#include <utility>
#include "assertions.hpp"
#include <exception>
#include <iostream>
#include <string>



import telar.gui.application.host_effects;
import telar.gui.application.sound_playback;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

void soundsCoalesceIntoOnePrioritizedSuccessor() {
  SoundPlayback playback;
  require(playback.request(AgentSound::ready).state == SoundRequestOutcome::State::start && playback.active(), "an idle permitted sound must reserve one worker");
  require(playback.request(AgentSound::ready).state == SoundRequestOutcome::State::queued, "an active worker must retain one successor");
  require(playback.request(AgentSound::needs_input).state == SoundRequestOutcome::State::queued, "input attention must coalesce with queued completion sounds");
  static_cast<void>(playback.request(AgentSound::ready));
  require(playback.queued() == AgentSound::needs_input, "later completion sounds must not replace pending input attention");
  require(playback.complete() == AgentSound::needs_input && playback.active() && !playback.queued(), "completion must transfer its reservation to the coalesced successor");
  require(!playback.complete() && !playback.active(), "an empty queue must release the worker");
}

void policyChangesLeaveRunningWorkAndRemoveDisallowedSuccessors() {
  SoundPlayback playback;
  static_cast<void>(playback.request(AgentSound::ready));
  static_cast<void>(playback.request(AgentSound::needs_input));
  playback.configure({.needs_input = false});
  require(playback.active() && !playback.queued(), "reconfiguration must remove only disallowed queued work");
  require(playback.request(AgentSound::needs_input).state == SoundRequestOutcome::State::ignored, "disabled sound kinds must not reserve a successor");
  require(!playback.complete() && !playback.active(), "a removed successor must not start after the active command ends");
  static_cast<void>(playback.request(AgentSound::ready));
  playback.schedulingFailed();
  require(!playback.active() && playback.request(AgentSound::ready).state == SoundRequestOutcome::State::start, "a failed background schedule must release its reservation for retry");
  playback.configure({.enabled = false});
  require(playback.active() && playback.request(AgentSound::ready).state == SoundRequestOutcome::State::ignored, "global disabling must let existing work finish without admitting new work");
  static_cast<void>(playback.complete());
}

void hostPayloadsOwnSanitizedBoundedUtf8() {
  std::string title = R"(A "quoted" title\)";
  const auto payload = NotificationPayload::create(title, "first\nsecond\tline\x7f");
  title.assign("changed");
  require(payload.title.view() == "A quoted title" && payload.message.view() == "firstsecondline", "host payloads must own text with the original quote, slash and control filtering");
  const std::string prefix(max_notification_title_bytes - 1, 'a');
  const auto truncated = NotificationPayload::create(prefix + "é", "message");
  require(truncated.title.view() == prefix, "a title ending inside a multibyte scalar must drop that whole scalar");
  const auto filtered = NotificationPayload::create(std::string(max_notification_title_bytes, '"') + "kept", std::string(max_notification_message_bytes + 1, 'b'));
  require(filtered.title.view() == "kept", "filtering must happen before the output capacity is consumed");
  require(filtered.message.view().size() == max_notification_message_bytes, "host detail storage must respect the shared wire capacity");
}

}

int main() try {
  soundsCoalesceIntoOnePrioritizedSuccessor();
  policyChangesLeaveRunningWorkAndRemoveDisallowedSuccessors();
  hostPayloadsOwnSanitizedBoundedUtf8();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
