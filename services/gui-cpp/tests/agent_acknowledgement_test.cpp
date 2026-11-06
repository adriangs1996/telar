#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "agent_fixture.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstddef>
#include <limits>
#include <string_view>
#include <array>
#include <span>
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "assertions.hpp"
#include "session_fixture.hpp"
#include <iostream>

#include "core/memory.hpp"


import telar.gui.application.host_effects;
import telar.gui.application.session;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::agentSnapshotEntry;
using telar::gui::test::deliver;
using telar::gui::test::openFirstPane;
using telar::gui::test::require;
using telar::gui::test::Transport;

std::size_t countAcknowledgements(const Transport &transport) {
  return static_cast<std::size_t>(std::ranges::count_if(transport.sent, [](const auto &message) {
    return !message.empty() && message.front() == static_cast<std::uint8_t>(ClientTag::acknowledge_agent);
  }));
}

void eachFocusedCompletionIsTakenOnce() {
  auto agent = agentSnapshotEntry();
  AgentAcknowledgement acknowledgement;
  require(!acknowledgement.take(&agent), "working agents must not consume an acknowledgement");
  agent.status = AgentStatus::done;
  const auto first = acknowledgement.take(&agent);
  require(first && first->pane_id == agent.pane_id && first->pane_generation == agent.pane_generation, "an unseen completion must retain its exact identity");
  require(!acknowledgement.take(&agent), "a retained completion must be acknowledged only once");
  const AgentSnapshotEntry *absent = nullptr;
  require(!acknowledgement.take(absent) && !acknowledgement.take(&agent), "missing focus must retain the current completion reservation");
  agent.status = AgentStatus::working;
  require(!acknowledgement.take(&agent), "a later turn must release the matching reservation");
  agent.status = AgentStatus::done;
  require(acknowledgement.take(&agent).has_value(), "a later completion of the same agent must be acknowledged again");
  ++agent.pane_generation;
  require(acknowledgement.take(&agent).has_value(), "pane reuse must not inherit an older generation's acknowledgement");
}

void committedSnapshotsAcknowledgeTheAlreadyFocusedPane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  std::array entries{agentSnapshotEntry()};
  std::uint64_t revision = 1;
  deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
  const auto initial = countAcknowledgements(transport);
  entries.front().status = AgentStatus::done;
  deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
  require(countAcknowledgements(transport) == initial + 1, "a completion arriving after focus must be acknowledged without another click");
  const auto request = transport.last<AcknowledgeAgent>();
  require(request.pane_id == entries.front().pane_id && request.pane_generation == entries.front().pane_generation, "the wire acknowledgement must use the committed snapshot identity");
  deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
  client.focusPane(entries.front().pane_id);
  require(countAcknowledgements(transport) == initial + 1, "repeated snapshots and repeated focus must not resend a completion");
  entries.front().status = AgentStatus::working;
  deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
  entries.front().status = AgentStatus::done;
  deliver(client, AgentSnapshot{.revision = revision, .entries = entries});
  require(countAcknowledgements(transport) == initial + 2, "a new turn must be able to complete and be acknowledged independently");
}

void onlyTheFocusedTabAndCommittedGenerationAreEligible() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  std::array entries{agentSnapshotEntry()};
  entries.front().status = AgentStatus::done;
  entries.front().location.tab_id = 2;
  const auto initial = countAcknowledgements(transport);
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  require(countAcknowledgements(transport) == initial, "an agent in another tab must remain unseen");
  entries.front().location.tab_id = 1;
  constexpr std::uint64_t current_generation = 9;
  entries.front().pane_generation = current_generation;
  deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
  require(countAcknowledgements(transport) == initial + 1 && transport.last<AcknowledgeAgent>().pane_generation == current_generation, "acknowledgements must use the snapshot generation rather than stale pane metadata");
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  const std::array duplicate{entries.front(), entries.front()};
  bool rejected = false;
  try {
    deliver(client, AgentSnapshot{.revision = 3, .entries = duplicate});
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected && countAcknowledgements(transport) == initial + 1, "stale and rejected snapshots must not publish an acknowledgement");
}

}

int main() try {
  eachFocusedCompletionIsTakenOnce();
  committedSnapshotsAcknowledgeTheAlreadyFocusedPane();
  onlyTheFocusedTabAndCommittedGenerationAreEligible();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
