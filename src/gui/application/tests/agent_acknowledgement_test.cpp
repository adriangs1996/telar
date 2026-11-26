#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <stdexcept>

import telar.testing;
import telar.gui.tests.agent_fixture;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.agents;
import telar.base.ds;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using telar::gui::test::agentSnapshotEntry;
  using namespace telar::gui::application::tests::session_fixture;

  std::size_t countAcknowledgements(const Transport& transport) {
    return static_cast<std::size_t>(std::ranges::count_if(transport.sent, [](const auto& message) {
      return !message.empty() && message.front() == static_cast<std::uint8_t>(ClientTag::acknowledge_agent);
    }));
  }

  application::FocusedAgent focused(const AgentSnapshotEntry& agent) {
    return {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .status = agent.status};
  }

  void eachFocusedCompletionIsTakenOnce() {
    auto agent = agentSnapshotEntry();
    application::AgentAcknowledgement acknowledgement;

    check(!acknowledgement.take(focused(agent)), "working agents must not consume an acknowledgement");
    agent.status = AgentStatus::done;
    const auto first = acknowledgement.take(focused(agent));

    check(first && first->pane_id == agent.pane_id && first->pane_generation == agent.pane_generation, "an unseen completion must retain its exact identity");
    check(!acknowledgement.take(focused(agent)), "a retained completion must be acknowledged only once");
    check(!acknowledgement.take(ds::none) && !acknowledgement.take(focused(agent)), "missing focus must retain the current completion reservation");
    agent.status = AgentStatus::working;
    check(!acknowledgement.take(focused(agent)), "a later turn must release the matching reservation");
    agent.status = AgentStatus::done;
    check(acknowledgement.take(focused(agent)).hasValue(), "a later completion of the same agent must be acknowledged again");
    ++agent.pane_generation;
    check(acknowledgement.take(focused(agent)).hasValue(), "pane reuse must not inherit an older generation's acknowledgement");
  }

  void committedSnapshotsAcknowledgeTheAlreadyFocusedPane() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ds::Array entries{agentSnapshotEntry()};
    std::uint64_t revision = 1;

    deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
    const auto initial = countAcknowledgements(transport);

    entries.atMut(0).status = AgentStatus::done;
    deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
    check(countAcknowledgements(transport) == initial + 1, "a completion arriving after focus must be acknowledged without another click");
    const auto request = transport.last<AcknowledgeAgent>();

    check(request.pane_id == entries.front().pane_id && request.pane_generation == entries.front().pane_generation, "the wire acknowledgement must use the committed snapshot identity");
    deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
    application::workbench::focusPane(client, entries.front().pane_id);
    check(countAcknowledgements(transport) == initial + 1, "repeated snapshots and repeated focus must not resend a completion");
    entries.atMut(0).status = AgentStatus::working;
    deliver(client, AgentSnapshot{.revision = revision++, .entries = entries});
    entries.atMut(0).status = AgentStatus::done;
    deliver(client, AgentSnapshot{.revision = revision, .entries = entries});
    check(countAcknowledgements(transport) == initial + 2, "a new turn must be able to complete and be acknowledged independently");
  }

  void onlyTheFocusedTabAndCommittedGenerationAreEligible() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ds::Array entries{agentSnapshotEntry()};

    entries.atMut(0).status = AgentStatus::done;
    entries.atMut(0).location.tab_id = 2;
    const auto initial = countAcknowledgements(transport);

    deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
    check(countAcknowledgements(transport) == initial, "an agent in another tab must remain unseen");
    entries.atMut(0).location.tab_id = 1;
    constexpr std::uint64_t current_generation = 9;

    entries.atMut(0).pane_generation = current_generation;
    deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
    check(countAcknowledgements(transport) == initial + 1 && transport.last<AcknowledgeAgent>().pane_generation == current_generation, "acknowledgements must use the snapshot generation rather than stale pane metadata");
    deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
    const ds::Array duplicate{entries.front(), entries.front()};
    bool rejected = false;

    try {
      deliver(client, AgentSnapshot{.revision = 3, .entries = duplicate});
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected && countAcknowledgements(transport) == initial + 1, "stale and rejected snapshots must not publish an acknowledgement");
  }

  const telar::testing::Case case_each_focused_completion_is_taken_once{"agent_acknowledgement.each_focused_completion_is_taken_once", eachFocusedCompletionIsTakenOnce};
  const telar::testing::Case case_committed_snapshots_acknowledge_the_already_focused_pane{"agent_acknowledgement.committed_snapshots_acknowledge_the_already_focused_pane", committedSnapshotsAcknowledgeTheAlreadyFocusedPane};
  const telar::testing::Case case_only_the_focused_tab_and_committed_generation_are_eligible{"agent_acknowledgement.only_the_focused_tab_and_committed_generation_are_eligible", onlyTheFocusedTabAndCommittedGenerationAreEligible};

}
