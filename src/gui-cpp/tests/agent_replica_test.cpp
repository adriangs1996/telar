#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include "../core/memory.hpp"
#include <algorithm>
#include <limits>
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "../terminal/screen.hpp"
#include <string_view>
#include <stdexcept>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <charconv>
#include <cstring>
#include <system_error>
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
#include <iostream>
#include <new>
#include <string>

#include "core/memory.hpp"

import telar.gui.tests.agent_fixture;
import telar.gui.tests.session_fixture;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.presentation.suggestion_labels;
import telar.gui.presentation.application_mark;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::agentSnapshotEntry;
using telar::gui::test::require;

constexpr std::uint64_t second = StatusAgeInterval::nanoseconds_per_second;
constexpr std::uint32_t initial_age = 5;
constexpr std::uint32_t advanced_age = 8;
constexpr std::uint64_t replacement_now_ns = 20 * second;
constexpr std::uint64_t provider_change_ns = 5 * second;
constexpr std::uint64_t generation_change_ns = 6 * second;
constexpr std::uint64_t stale_delivery_ns = 8 * second;

void fractionsAndResets() {
  StatusAge clock;
  StatusAgeSample sample{.pane_id = 1, .pane_generation = 1, .status = AgentStatus::working, .provider = AgentProvider::codex, .reported_seconds = initial_age};
  clock.observe(sample, second);
  clock.observe(sample, second + (second / 2));
  require(clock.interval().seconds(2 * second) == initial_age + 1, "same-age reports must retain fractional progress");
  sample.reported_seconds = advanced_age;
  clock.observe(sample, 2 * second);
  require(clock.interval().seconds(3 * second) == advanced_age + 1, "newer reported ages must advance the baseline");
  sample.reported_seconds = 2;
  clock.observe(sample, 3 * second);
  require(clock.interval().seconds(3 * second) == 2, "decreasing reports must reset the interval");
  sample.status = AgentStatus::ready;
  clock.observe(sample, 4 * second);
  require(clock.interval().seconds(4 * second) == 2, "status transitions must reset elapsed age");
  sample.provider = AgentProvider::claude;
  clock.observe(sample, provider_change_ns);
  require(clock.interval().seconds(provider_change_ns) == 2, "provider replacement must reset elapsed age");
  ++sample.pane_generation;
  clock.observe(sample, generation_change_ns);
  require(clock.interval().seconds(generation_change_ns) == 2, "pane reuse must reset elapsed age");
  require(clock.interval().seconds(0) == 2, "backward timestamps must not subtract age");
  constexpr StatusAgeInterval saturated{.age_ns = std::numeric_limits<std::uint64_t>::max() - second, .sampled_ns = 0};
  require(saturated.elapsed(std::numeric_limits<std::uint64_t>::max()) == std::numeric_limits<std::uint64_t>::max(), "elapsed nanoseconds must saturate");
  require(saturated.seconds(std::numeric_limits<std::uint64_t>::max()) == std::numeric_limits<std::uint32_t>::max(), "display seconds must saturate");
}

void revisionsAndSourceReplacement() {
  SystemAllocator memory;
  AgentReplica replica{memory};
  std::array entries{agentSnapshotEntry(initial_age), agentSnapshotEntry(initial_age)};
  entries.back().pane_id = 2;
  require(replica.apply({.revision = 1, .entries = entries}, second), "first revision must be accepted");
  require(!replica.apply({.revision = 1, .entries = {}}, stale_delivery_ns), "duplicate revisions must not erase agents");
  require(replica.entries().size() == 2 && replica.revision() == 1, "duplicate revisions must preserve the replica");
  std::swap(entries.front(), entries.back());
  require(replica.apply({.revision = 2, .entries = entries}, second + (second / 2)), "reordering must commit");
  require(replica.entries().front().pane_id == 2 && replica.entries().front().status_clock.interval().seconds(2 * second) == initial_age + 1, "clocks must follow identity through reordering");
  entries.back() = entries.front();
  bool rejected = false;
  try {
    replica.apply({.revision = 3, .entries = entries}, 3 * second);
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected && replica.revision() == 2 && replica.entries().back().pane_id == 1, "duplicate identities must preserve the entire previous revision");
  replica.resetSource();
  require(replica.entries().size() == 2, "offline presentation must retain the last entries");
  entries.back().pane_id = 1;
  require(replica.apply({.revision = 1, .entries = entries}, replacement_now_ns), "replacement runtime may restart its revision counter");
  require(replica.entries().front().status_clock.interval().seconds(replacement_now_ns) == initial_age, "replacement runtime must not inherit a retired clock");
}

void attachmentCapabilitiesFollowExactAgentIdentities() {
  SystemAllocator memory;
  AgentReplica replica{memory};
  std::array entries{agentSnapshotEntry(), agentSnapshotEntry()};
  entries[0].attachments = AgentAttachmentMarkers::stable_number;
  entries[1].pane_id = 2;
  entries[1].attachments = AgentAttachmentMarkers::pasted_path;
  require(replica.apply({.revision = 1, .entries = entries}, second), "initial attachment capabilities must commit");
  require(replica.entries()[0].attachments == AgentAttachmentMarkers::stable_number && replica.entries()[1].attachments == AgentAttachmentMarkers::pasted_path, "each identity must retain the marker policy its manifest reports");

  std::swap(entries[0], entries[1]);
  entries[1].attachments = AgentAttachmentMarkers::ordered;
  require(replica.apply({.revision = 2, .entries = entries}, 2 * second), "reordering and a capability update must commit together");
  require(replica.entries()[0].pane_id == 2 && replica.entries()[0].attachments == AgentAttachmentMarkers::pasted_path && replica.entries()[1].attachments == AgentAttachmentMarkers::ordered, "capabilities must follow snapshot identities through staging reuse");

  ++entries[0].pane_generation;
  entries[0].attachments = AgentAttachmentMarkers::none;
  require(replica.apply({.revision = 3, .entries = entries}, 3 * second), "a replacement agent must commit");
  require(replica.entries()[0].attachments == AgentAttachmentMarkers::none, "an incapable replacement must not inherit a previous agent's shelf");
}

void statusChangesFollowCommittedIdentities() {
  SystemAllocator memory;
  AgentReplica replica{memory};
  std::array entries{agentSnapshotEntry(), agentSnapshotEntry(), agentSnapshotEntry()};
  entries[1].pane_id = 2;
  entries[2].pane_id = 3;
  replica.apply({.revision = 1, .entries = entries}, second);
  require(replica.statusChanges().empty(), "initial identities must not raise alerts");

  std::swap(entries[0], entries[2]);
  entries[0].status = AgentStatus::blocked;
  constexpr std::uint16_t changed_pane_index = 9;
  entries[0].pane_index = changed_pane_index;
  entries[0].provider = AgentProvider::claude;
  entries[1].status = AgentStatus::done;
  ++entries[1].pane_generation;
  replica.apply({.revision = 2, .entries = entries}, 2 * second);
  const auto changes = replica.statusChanges();
  require(changes.size() == 1, "a replacement generation must not inherit a prior status");
  require(changes.front().pane_id == 3 && changes.front().pane_index == changed_pane_index && changes.front().provider == AgentProvider::claude, "changes must retain new metadata in snapshot order");
  require(changes.front().previous == AgentStatus::working && changes.front().current == AgentStatus::blocked, "changes must name both committed statuses");

  entries[0].status = AgentStatus::failed;
  entries[2] = entries[0];
  bool rejected = false;
  try {
    replica.apply({.revision = 3, .entries = entries}, 3 * second);
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected && replica.statusChanges().size() == 1 && replica.statusChanges().front().current == AgentStatus::blocked, "invalid snapshots must not publish partial transitions");
  replica.resetSource();
  require(replica.statusChanges().empty(), "source retirement must clear pending transitions");
  entries[2].pane_id = 4;
  replica.apply({.revision = 1, .entries = entries}, replacement_now_ns);
  require(replica.statusChanges().empty(), "reconnection must not compare new agents with retired source metadata");
  replica.apply({.revision = 2, .entries = entries}, replacement_now_ns);
  require(replica.statusChanges().empty(), "unchanged statuses must not repeat alerts");
}

class RejectingAllocator {
public:
  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return rejecting_ ? nullptr : budget_.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    budget_.deallocate(pointer, size, alignment);
  }

  [[nodiscard]] std::size_t liveBytes() const noexcept {
    return budget_.liveBytes();
  }

  void setRejecting(bool rejecting) noexcept {
    rejecting_ = rejecting;
  }

private:
  static constexpr std::size_t capacity = std::size_t{1024} * 1024;
  bool rejecting_ = false;
  SystemAllocator system_;
  BudgetAllocator<SystemAllocator> budget_{system_, capacity};
};

void allocationFailurePreservesTheReplica() {
  RejectingAllocator memory;
  {
    AgentReplica replica{memory};
    std::array entries{agentSnapshotEntry(initial_age)};
    replica.apply({.revision = 1, .entries = entries}, second);
    replica.apply({.revision = 2, .entries = entries}, second);
    const auto interval = replica.entries().front().status_clock.interval();
    const auto live_bytes = memory.liveBytes();
    const std::string title(80, 'x');
    entries.front().session_title = title;
    entries.front().status = AgentStatus::blocked;
    memory.setRejecting(true);
    bool rejected = false;
    try {
      replica.apply({.revision = 3, .entries = entries}, 4 * second);
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    require(rejected && replica.revision() == 2, "allocation failure must not publish a revision");
    require(replica.statusChanges().empty(), "allocation failure must not publish status transitions");
    require(replica.entries().front().title == "Initial" && replica.entries().front().status == AgentStatus::working, "allocation failure must not partially replace metadata");
    require(replica.entries().front().status_clock.interval() == interval && memory.liveBytes() == live_bytes, "allocation failure must preserve clocks and release temporary allocations");
    memory.setRejecting(false);
    require(replica.apply({.revision = 3, .entries = entries}, 4 * second), "a failed revision must be retryable");
    require(replica.statusChanges().size() == 1 && replica.statusChanges().front().current == AgentStatus::blocked, "successful retry must publish its transition once");
  }

  require(memory.liveBytes() == 0, "replica destruction must release injected storage");
}

void warmedSnapshotsReuseStorage() {
  SystemAllocator upstream;
  constexpr std::size_t budget_bytes = std::size_t{1024} * 1024;
  constexpr std::size_t title_bytes = 80;
  BudgetAllocator memory{upstream, budget_bytes};
  AgentReplica replica{memory};
  std::string title(title_bytes, 'x');
  std::array<AgentSnapshotEntry, decltype(replica)::capacity> entries;
  for (std::size_t index = 0; index < entries.size(); ++index) {
    entries[index] = agentSnapshotEntry(initial_age);
    entries[index].pane_id = index + 1;
    entries[index].pane_index = static_cast<std::uint16_t>(index + 1);
    entries[index].session_title = title;
  }

  replica.apply({.revision = 1, .entries = entries}, second);
  replica.apply({.revision = 2, .entries = entries}, second);
  const auto allocations = memory.allocations();
  constexpr std::uint64_t revisions = 100;
  constexpr std::uint64_t alphabet_size = 26;
  for (std::uint64_t revision = 3; revision <= revisions; ++revision) {
    title.front() = static_cast<char>('a' + (revision % alphabet_size));
    replica.apply({.revision = revision, .entries = entries}, revision * second);
  }

  require(memory.allocations() == allocations, "repeated full snapshots with warmed string capacities must not allocate");
  std::cout << "Warm agent snapshots: entries=" << entries.size() << ", additional_allocations=" << memory.allocations() - allocations << '\n';
}

struct FakeClock {
  static inline std::uint64_t current = 0;

  static std::uint64_t nowNanoseconds() noexcept {
    return current;
  }
};

void sessionUsesTheInjectedClock() {
  SystemAllocator memory;
  telar::gui::test::Transport transport;
  Session<SystemAllocator, telar::gui::test::Transport, FakeClock> session{memory, transport};
  const std::array entries{agentSnapshotEntry(initial_age)};
  FakeClock::current = second;
  telar::gui::test::deliver(session, AgentSnapshot{.revision = 1, .entries = entries});
  require(session.agents().front().status_clock.interval().sampled_ns == second, "session must use the compile-time clock dependency");
  session.disconnected();
  FakeClock::current = replacement_now_ns;
  telar::gui::test::deliver(session, AgentSnapshot{.revision = 1, .entries = entries});
  require(session.agents().front().status_clock.interval().sampled_ns == FakeClock::current, "session disconnect must retire the previous clock source");
}

void paneListRevisions() {
  SystemAllocator memory;
  telar::gui::test::Transport transport;
  Session<SystemAllocator, telar::gui::test::Transport, FakeClock> session{memory, transport};
  const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  const std::array<std::uint16_t, 2> ports{3000, 9229};
  std::array entries{
      PaneListEntry{.pane_id = 1, .pane_generation = 1, .location = location, .foreground = "node", .foreground_age_s = initial_age, .ports = ports},
      PaneListEntry{.pane_id = 2, .pane_generation = 1, .location = location, .foreground = "zsh", .shell = true},
  };
  FakeClock::current = second;
  telar::gui::test::deliver(session, PaneList{.revision = 2, .entries = entries});
  const auto listed = session.paneList();
  require(session.paneListRevision() == 2 && listed.size() == 2 && listed.front().foreground.view() == "node" && listed.back().shell, "the pane list must replace the replica");
  require(listed.front().age.seconds(2 * second) == initial_age + 1, "a foreground age must advance from its arrival");
  require(std::ranges::equal(listed.front().ports(), ports) && listed.back().ports().empty(), "listening ports must follow their pane");
  const std::array<std::uint16_t, 2> unordered{9229, 3000};
  bool unsorted = false;
  try {
    telar::gui::test::deliver(session, PaneList{.revision = 3, .entries = std::array{PaneListEntry{.pane_id = 1, .pane_generation = 1, .location = location, .foreground = "node", .ports = unordered}}});
  } catch (const EncodingError &) {
    unsorted = true;
  }

  require(unsorted && session.paneListRevision() == 2, "unordered ports must be rejected");
  telar::gui::test::deliver(session, PaneList{.revision = 2, .entries = {}});
  require(session.paneList().size() == 2, "a stale revision must not replace the pane list");
  entries.back().pane_id = 1;
  bool rejected = false;
  try {
    telar::gui::test::deliver(session, PaneList{.revision = 3, .entries = entries});
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected && session.paneListRevision() == 2 && session.paneList().back().pane_id == 2, "a duplicate pane must preserve the previous list");
  session.disconnected();
  telar::gui::test::deliver(session, PaneList{.revision = 1, .entries = std::span{entries}.first(1)});
  require(session.paneListRevision() == 1 && session.paneList().size() == 1, "a replacement runtime may restart its revision counter");
}

void animationBoundaries() {
  constexpr auto interval = AgentAnimation::pulse_interval_ns;
  require(AgentAnimation::deadline(AgentStatus::working, true, interval) == 2 * interval, "working animation must request the next global 120 ms boundary");
  require(AgentAnimation::deadline(AgentStatus::ready, true, second) == 2 * second, "ready clocks must request the next global second");
  require(!AgentAnimation::deadline(AgentStatus::blocked, true, second), "blocked status must not animate");
  require(!AgentAnimation::deadline(AgentStatus::working, false, second), "offline status must not animate");
  constexpr std::uint64_t frame_rollover = 256;
  require(AgentAnimation::alpha(frame_rollover * interval) == AgentAnimation::alpha(0), "pulse phase must retain the original eight-bit rollover");
}

}

int main() try {
  fractionsAndResets();
  revisionsAndSourceReplacement();
  attachmentCapabilitiesFollowExactAgentIdentities();
  statusChangesFollowCommittedIdentities();
  allocationFailurePreservesTheReplica();
  warmedSnapshotsReuseStorage();
  sessionUsesTheInjectedClock();
  paneListRevisions();
  animationBoundaries();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
