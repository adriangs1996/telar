#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <memory>
#include <stdexcept>
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <concepts>
#include <utility>
#include "../terminal/screen.hpp"
#include <string_view>
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
#include "assertions.hpp"
#include <iostream>

#include "core/memory.hpp"

import telar.gui.tests.session_fixture;
import telar.gui.application.sound_playback;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

constexpr WorkspaceLocation first_workspace{.kind = WorkspaceLocation::Kind::workspace, .id = 1};
constexpr WorkspaceLocation second_workspace{.kind = WorkspaceLocation::Kind::workspace, .id = 2};
constexpr WorkspaceLocation project_workspace{.kind = WorkspaceLocation::Kind::workspace, .id = 9};
constexpr WorkspaceLocation unknown_workspace{.kind = WorkspaceLocation::Kind::workspace, .id = 78};
constexpr std::uint64_t first_worktree = 31;
constexpr std::uint64_t second_worktree = 32;
constexpr std::array entries{
    WorkspaceListEntry{.workspace = first_workspace.id, .name = "Current", .path = "/current"},
    WorkspaceListEntry{.workspace = second_workspace.id, .name = "Other", .path = "/other"},
    WorkspaceListEntry{.workspace = project_workspace.id, .name = "Project", .path = "/project"},
};
constexpr std::array worktrees{
    WorktreeListEntry{.worktree = first_worktree, .source = project_workspace.id, .workspace = first_workspace.id, .path = "/current", .branch = "current"},
    WorktreeListEntry{.worktree = second_worktree, .source = project_workspace.id, .workspace = second_workspace.id, .path = "/other", .branch = "other"},
};

template <typename Client>
void finishWorkspaceArrival(Client &client, Transport &transport, TabLocation location, std::uint64_t pane_id) {
  const auto opening = transport.last<OpenPane>();
  deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .pane_generation = 1});
  const std::array panes{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
  const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "Visited", .tabs = tabs});
  require(!client.requestsPending(), "The fixture must finish both canonical arrival requests");
}

void aWorkspaceReturnRestoresItsTreeAfterCanonicalMembership() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  const auto source = client.activeTab()->location;
  require(client.split(ClientLayoutAxis::vertical), "The fixture must own a non-default split tree");
  const auto split = transport.last<CreatePane>();
  constexpr std::uint64_t remembered_pane = 3;
  deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = remembered_pane, .location = source, .created = true, .pane_generation = 1});
  client.toggleFullscreen();
  client.selectWorkspace(second_workspace);
  finishWorkspaceArrival(client, transport, {.workspace = second_workspace, .tab_id = second_workspace.id}, second_workspace.id);
  client.selectWorkspace(first_workspace);
  const auto returning = transport.last<OpenPane>();
  require(returning.target.kind == PaneTarget::Kind::pane && returning.target.id == remembered_pane && !returning.launch, "Returning must reopen the remembered focus instead of selecting the runtime's default tab");
  deliver(client, PaneOpened{.request_id = returning.request_id, .pane_id = remembered_pane, .location = source, .pane_generation = 1});
  require(client.activeTab()->layout.nodes().size() == 1 && !client.activeTab()->fullscreen, "Canonical arrival must stage a single provisional root before restoring remembered presentation");
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = remembered_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = source, .panes = panes});
  const auto *axis = std::get_if<ClientLayoutSplit>(&client.activeTab()->layout.nodes().front());
  require(axis != nullptr && axis->axis == ClientLayoutAxis::vertical && client.activeTab()->fullscreen && client.activeTab()->focused_pane == remembered_pane, "Canonical membership must restore the remembered split, fullscreen and focused pane together");
}

void aMissingBookmarkRetriesItsWorkspaceOnlyOnce() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  client.selectWorkspace(second_workspace);
  finishWorkspaceArrival(client, transport, {.workspace = second_workspace, .tab_id = second_workspace.id}, second_workspace.id);
  client.selectWorkspace(first_workspace);
  const auto returning = transport.last<OpenPane>();
  require(returning.target.kind == PaneTarget::Kind::pane && returning.target.id == 1, "The first return must use its remembered pane");
  deliver(client, RequestFailed{.request_id = returning.request_id, .code = FailureCode::pane_not_found, .message = "The pane is gone"});
  const auto fallback = transport.last<OpenPane>();
  require(fallback.request_id != returning.request_id && fallback.target.kind == PaneTarget::Kind::workspace && fallback.target.id == first_workspace.id && !fallback.launch, "A missing remembered pane must fall back to that exact workspace once");
  const auto openings = transport.count(ClientTag::open_pane);
  deliver(client, RequestFailed{.request_id = fallback.request_id, .code = FailureCode::pane_not_found, .message = "No fallback pane"});
  require(!client.requestsPending() && transport.count(ClientTag::open_pane) == openings, "Failure of the fallback must not repeat an open indefinitely");
}

void canonicalArrivalUsesTheSavedTreeOfItsActualTab() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.connected(1);
  const TabLocation remembered{.workspace = first_workspace, .tab_id = 1};
  const TabLocation arrived{.workspace = first_workspace, .tab_id = 2};
  constexpr std::uint64_t remembered_pane = 3;
  constexpr std::uint64_t arrived_pane = 11;
  constexpr std::uint64_t arrived_focus = 12;
  const std::array<ClientLayoutNode, 1> remembered_nodes{ClientLayoutPane{remembered_pane}};
  const std::array<ClientLayoutNode, 3> arrived_nodes{ClientLayoutSplit{.axis = ClientLayoutAxis::vertical, .ratio = PaneLayout::ratio_half}, ClientLayoutPane{arrived_pane}, ClientLayoutPane{arrived_focus}};
  const std::array layouts{
      ClientTabLayout{.location = remembered, .focused_pane = remembered_pane, .fullscreen = true, .workspace_active = true, .nodes = remembered_nodes},
      ClientTabLayout{.location = arrived, .focused_pane = arrived_focus, .nodes = arrived_nodes},
  };
  deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_width = decltype(client)::default_sidebar_columns, .active_tab = remembered, .tabs = layouts});
  const auto opening = transport.last<OpenPane>();
  require(opening.target.id == remembered_pane, "Bootstrap must first request its remembered pane");
  deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = arrived_pane, .location = arrived, .pane_generation = 1});
  require(client.activeTab()->layout.nodes().size() == 1 && !client.activeTab()->fullscreen, "A different canonical arrival must still stage a provisional root");
  const std::array panes{PaneDescriptor{.pane_id = arrived_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = arrived_focus, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = arrived, .panes = panes});
  const auto *axis = std::get_if<ClientLayoutSplit>(&client.activeTab()->layout.nodes().front());
  require(axis != nullptr && axis->axis == ClientLayoutAxis::vertical && client.activeTab()->focused_pane == arrived_focus && !client.activeTab()->fullscreen, "The actual tab's saved tree and focus must win over another tab's workspace bookmark");
}

void aNewConnectionForgetsPreviousNavigationAndSavedTrees() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  require(client.split(ClientLayoutAxis::vertical), "The previous connection must own a non-default remembered tree");
  const auto split = transport.last<CreatePane>();
  constexpr std::uint64_t old_focus = 3;
  deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = old_focus, .location = client.activeTab()->location, .created = true, .pane_generation = 1});
  client.toggleFullscreen();
  client.selectWorkspace(second_workspace);
  finishWorkspaceArrival(client, transport, {.workspace = second_workspace, .tab_id = second_workspace.id}, second_workspace.id);
  client.disconnected();
  client.connected(2);
  const auto messages = transport.sent.size();
  require(!client.selectWorkspace(first_workspace) && transport.sent.size() == messages, "A new connection must wait for a fresh workspace replica");
  const TabLocation current{.workspace = second_workspace, .tab_id = second_workspace.id};
  const std::array<ClientLayoutNode, 1> current_nodes{ClientLayoutPane{second_workspace.id}};
  const std::array current_layouts{ClientTabLayout{.location = current, .focused_pane = second_workspace.id, .workspace_active = true, .nodes = current_nodes}};
  deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_width = decltype(client)::default_sidebar_columns, .active_tab = current, .tabs = current_layouts});
  finishWorkspaceArrival(client, transport, current, second_workspace.id);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  require(client.selectWorkspace(first_workspace), "Fresh canonical metadata must admit navigation again");
  const auto opening = transport.last<OpenPane>();
  require(opening.target.kind == PaneTarget::Kind::workspace && opening.target.id == first_workspace.id, "A new connection must not reopen the previous connection's remembered pane");
  const TabLocation arrived{.workspace = first_workspace, .tab_id = first_workspace.id};
  deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = 1, .location = arrived, .pane_generation = 2});
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 2}, PaneDescriptor{.pane_id = old_focus, .lifecycle = PaneLifecycle::running, .pane_generation = 2}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = arrived, .panes = panes});
  const auto *axis = std::get_if<ClientLayoutSplit>(&client.activeTab()->layout.nodes().front());
  require(axis != nullptr && axis->axis == ClientLayoutAxis::horizontal && !client.activeTab()->fullscreen && client.activeTab()->focused_pane == 1, "Reused tab/pane IDs must not resurrect an old connection's saved tree, fullscreen or focus");
}

void lateMetadataCannotActivateTheDepartedWorkspace() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  const auto source = client.activeTab()->location;
  client.selectWorkspace(second_workspace);
  const auto openings = transport.count(ClientTag::open_pane);
  const std::array tabs{TabDescriptor{.tab_id = source.tab_id, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = source.workspace, .name = "Late source", .tabs = tabs});
  require(client.activeTab() == nullptr && client.panes().empty() && transport.count(ClientTag::open_pane) == openings, "Late source metadata must not replace an outstanding canonical workspace arrival");
}

void linkedCheckoutsDoNotConsumeProjectPositions() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries, .worktrees = worktrees});
  const auto messages = transport.sent.size();
  constexpr std::size_t checkout_position = 2;
  client.selectWorkspaceIndex(checkout_position);
  require(transport.sent.size() == messages, "Project-position shortcuts must exclude linked checkout workspaces");
}

TabLocation historyLocation(std::uint64_t identity) {
  return {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = identity}, .tab_id = identity};
}

NavigationHistory::Layout completeLayout(std::uint64_t first) {
  PaneLayout layout;
  for (std::size_t index = 0; index < PaneLayout::maximum_panes; ++index) {
    require(layout.add(first + index, ClientLayoutAxis::vertical, first), "The fixture must build a full valid tree");
  }

  return NavigationHistory::Layout{layout.nodes()};
}

void boundedHistoryUpdatesAndReusesFreeSlots() {
  NavigationHistory history;
  for (std::size_t index = 0; index < NavigationHistory::capacity; ++index) {
    const auto location = historyLocation(index + 1);
    history.remember({.location = location, .pane_id = location.tab_id});
  }

  const auto overflow = historyLocation(NavigationHistory::capacity + 1);
  history.remember({.location = overflow, .pane_id = overflow.tab_id});
  require(history.find(overflow.workspace) == nullptr, "A full bookmark table must preserve its admitted workspaces");
  constexpr std::uint64_t changed_pane = 900;
  history.remember({.location = historyLocation(1), .pane_id = changed_pane});
  require(history.find(first_workspace)->pane_id == changed_pane, "Updating an existing bookmark must work at capacity");
  history.forget(second_workspace);
  history.remember({.location = overflow, .pane_id = overflow.tab_id});
  require(history.find(overflow.workspace) != nullptr && history.find(second_workspace) == nullptr, "Forgetting must release one bounded bookmark slot");
  history.clear();
  require(history.find(first_workspace) == nullptr && history.find(overflow.workspace) == nullptr, "A new session must discard all admitted bookmarks");
}

void savedLayoutOverflowIsAtomicAndEvictsTheOldestTree() {
  SavedLayouts layouts;
  constexpr std::uint64_t first_identity = 100;
  const auto tree = completeLayout(first_identity);
  constexpr auto rows_that_fit = SavedLayouts::node_capacity / PaneLayout::maximum_nodes;
  for (std::size_t index = 0; index < rows_that_fit; ++index) {
    require(layouts.remember({.location = historyLocation(index + 1), .pane_id = first_identity, .focused_pane = first_identity, .nodes = tree.view()}), "The node pool must admit complete valid trees while space remains");
  }

  const auto before_nodes = layouts.nodeCount();
  const auto rejected = historyLocation(rows_that_fit + 1);
  require(!layouts.remember({.location = rejected, .pane_id = first_identity, .focused_pane = first_identity, .nodes = tree.view()}), "Node exhaustion must reject an atomic saved-layout insertion");
  require(layouts.size() == rows_that_fit && layouts.nodeCount() == before_nodes && layouts.find(historyLocation(1)).has_value(), "A refused insertion must preserve every admitted row and node");
  layouts.retain({.location = rejected, .pane_id = first_identity, .focused_pane = first_identity, .nodes = tree.view()});
  require(layouts.size() == rows_that_fit && layouts.nodeCount() == before_nodes && !layouts.find(historyLocation(1)) && layouts.find(rejected), "Navigation retention must evict only the oldest required complete tree");
  constexpr std::uint64_t replacement_identity = 700;
  const std::array<ClientLayoutNode, 1> replacement{ClientLayoutPane{replacement_identity}};
  layouts.retain({.location = rejected, .pane_id = replacement_identity, .focused_pane = replacement_identity, .fullscreen = true, .nodes = replacement});
  const auto updated = layouts.find(rejected);
  require(updated && updated->fullscreen && updated->focused_pane == replacement_identity && updated->nodes.size() == 1, "Updating a saved row must replace presentation and compact its old tree together");
  layouts.forget(historyLocation(2));
  const auto remaining = layouts.find(rejected);
  require(!layouts.find(historyLocation(2)) && remaining && remaining->nodes.size() == 1, "Removing an older tree must preserve compacted later row offsets");
}

void savedLayoutRetentionOwnsAnAliasedTreeBeforeEviction() {
  SavedLayouts layouts;
  constexpr auto rows_that_fit = SavedLayouts::node_capacity / PaneLayout::maximum_nodes;
  constexpr std::uint64_t identity_stride = 100;
  for (std::size_t index = 0; index < rows_that_fit; ++index) {
    const auto first = (index + 1) * identity_stride;
    const auto tree = completeLayout(first);
    layouts.retain({.location = historyLocation(index + 1), .pane_id = first, .focused_pane = first, .nodes = tree.view()});
  }

  auto borrowed = layouts.at(0);
  const auto original_tail = std::get<ClientLayoutPane>(borrowed.nodes.back()).pane_id;
  borrowed.location = historyLocation(rows_that_fit + 1);
  layouts.retain(borrowed);
  const auto retained = layouts.find(borrowed.location);
  require(retained && std::get<ClientLayoutPane>(retained->nodes.back()).pane_id == original_tail, "Evicting an aliased source row must not substitute the following tree's nodes");
}

void savedLayoutRowsAreBoundedIndependentlyOfTheirNodePool() {
  SavedLayouts layouts;
  constexpr std::uint64_t pane_id = 1;
  const std::array<ClientLayoutNode, 1> nodes{ClientLayoutPane{pane_id}};
  for (std::size_t index = 0; index < SavedLayouts::capacity; ++index) {
    require(layouts.remember({.location = historyLocation(index + 1), .pane_id = pane_id, .focused_pane = pane_id, .nodes = nodes}), "Each available row must admit one valid pane");
  }

  const auto overflow = historyLocation(SavedLayouts::capacity + 1);
  require(!layouts.remember({.location = overflow, .pane_id = pane_id, .focused_pane = pane_id, .nodes = nodes}), "Row exhaustion must reject even while the node pool has room");
  layouts.retain({.location = overflow, .pane_id = pane_id, .focused_pane = pane_id, .nodes = nodes});
  require(layouts.size() == SavedLayouts::capacity && !layouts.find(historyLocation(1)) && layouts.find(overflow), "Retention at row capacity must evict the oldest row without exceeding either bound");
  layouts.clear();
  require(layouts.size() == 0 && layouts.nodeCount() == 0 && !layouts.find(overflow), "New session adoption must release saved row and node ownership");
  require(layouts.remember({.location = overflow, .nodes = {}}), "The original saved table may retain a default empty layout row");
  require(layouts.size() == 1 && layouts.nodeCount() == 0 && !layouts.find(overflow), "An empty retained row must not be exposed as a reconstructable saved layout");
}

void unknownSelectionDoesNotContactTheRuntime() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  const auto messages = transport.sent.size();
  client.selectWorkspace(unknown_workspace);
  require(transport.sent.size() == messages && client.focusedPane()->id == 1, "An unknown workspace must not request metadata or leave the current pane");
}

void selectingTheActiveWorkspaceIsAnIdleNoOp() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  const auto messages = transport.sent.size();
  client.selectWorkspace(first_workspace);
  require(transport.sent.size() == messages && !client.requestsPending(), "Selecting the active workspace must preserve the idle request tracker");
}

void uncachedSelectionOpensTheRuntimeWorkspaceAfterDetaching() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  const auto first = transport.sent.size();
  const auto openings = transport.count(ClientTag::open_pane);
  client.selectWorkspace(second_workspace);
  require(transport.count(ClientTag::open_pane) == openings + 1, "An uncached known workspace must open through the runtime instead of requesting metadata alone");
  const auto request = transport.last<OpenPane>();
  require(request.target.kind == PaneTarget::Kind::workspace && request.target.id == second_workspace.id && !request.launch, "Workspace selection must attach an authoritative existing target without sending a launch command");
  const auto messages = std::span{transport.sent}.subspan(first);
  const auto detach = std::ranges::find_if(messages, [](const auto &bytes) {
    return bytes.front() == static_cast<Byte>(ClientTag::detach_pane);
  });
  const auto opening = std::ranges::find_if(messages, [](const auto &bytes) {
    return bytes.front() == static_cast<Byte>(ClientTag::open_pane);
  });
  require(detach < opening && opening != messages.end(), "Every departure must reach the runtime before its target open");
  require(client.activeTab() == nullptr && client.panes().empty() && client.requestsPending(), "A queued workspace handoff must await canonical arrival without retaining the previous screen");
}

void aPendingOperationFencesWorkspaceSelection() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  require(client.createTab("Pending") == TabCreationOutcome::requested, "The fixture must own an outstanding tab request");
  const auto messages = transport.sent.size();
  client.selectWorkspace(second_workspace);
  require(transport.sent.size() == messages && client.focusedPane()->id == 1 && client.focusedPane()->attached, "Pending requests must fence workspace selection before any departure or metadata query");
}

void disconnectedSelectionDoesNotUseRetainedMetadata() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries});
  client.disconnected();
  const auto messages = transport.sent.size();
  client.selectWorkspace(second_workspace);
  require(transport.sent.size() == messages, "A disconnected client must not navigate using its retained workspace list");
}

void worktreeActionsUseTheSharedRuntimeHandoff() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, WorkspaceList{.revision = 1, .entries = entries, .worktrees = worktrees});
  const auto openings = transport.count(ClientTag::open_pane);
  require(client.leaveWorktree(), "A linked checkout must select its source project");
  require(transport.count(ClientTag::open_pane) == openings + 1, "Leaving a checkout must hand off to its source project instead of only reading its metadata");
  const auto request = transport.last<OpenPane>();
  require(request.target.kind == PaneTarget::Kind::workspace && request.target.id == project_workspace.id && !request.launch, "The project source must remain the exact runtime target of leaving a worktree");
}

}

int main() {
  constexpr std::array cases{
      std::pair{"history-capacity", &boundedHistoryUpdatesAndReusesFreeSlots},
      std::pair{"saved-nodes", &savedLayoutOverflowIsAtomicAndEvictsTheOldestTree},
      std::pair{"saved-alias", &savedLayoutRetentionOwnsAnAliasedTreeBeforeEviction},
      std::pair{"saved-rows", &savedLayoutRowsAreBoundedIndependentlyOfTheirNodePool},
      std::pair{"canonical-tree", &aWorkspaceReturnRestoresItsTreeAfterCanonicalMembership},
      std::pair{"canonical-tab", &canonicalArrivalUsesTheSavedTreeOfItsActualTab},
      std::pair{"reconnect-navigation", &aNewConnectionForgetsPreviousNavigationAndSavedTrees},
      std::pair{"missing-bookmark", &aMissingBookmarkRetriesItsWorkspaceOnlyOnce},
      std::pair{"late-metadata", &lateMetadataCannotActivateTheDepartedWorkspace},
      std::pair{"project-position", &linkedCheckoutsDoNotConsumeProjectPositions},
      std::pair{"unknown", &unknownSelectionDoesNotContactTheRuntime},
      std::pair{"active", &selectingTheActiveWorkspaceIsAnIdleNoOp},
      std::pair{"uncached", &uncachedSelectionOpensTheRuntimeWorkspaceAfterDetaching},
      std::pair{"busy", &aPendingOperationFencesWorkspaceSelection},
      std::pair{"disconnected", &disconnectedSelectionDoesNotUseRetainedMetadata},
      std::pair{"worktree", &worktreeActionsUseTheSharedRuntimeHandoff},
  };
  int failures = 0;
  for (const auto &[name, run] : cases) {
    try {
      run();
      std::cout << "PASS " << name << '\n';
    } catch (const std::exception &error) {
      ++failures;
      std::cerr << "FAIL " << name << ": " << error.what() << '\n';
    }
  }

  return failures;
}
