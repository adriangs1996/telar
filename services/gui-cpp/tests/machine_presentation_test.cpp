#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "agent_fixture.hpp"
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
#include <concepts>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <string_view>
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


import telar.gui.application.sound_playback;
import telar.gui.application.session;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

template <typename Client>
void finishSnapshots(Client &client, Transport &transport, TabLocation location, std::span<const PaneDescriptor> panes) {
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
  const std::array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = static_cast<std::uint16_t>(panes.size())}};
  deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
}

template <typename Client>
void openWithPendingWorkspaceSnapshot(Client &client, Transport &transport) {
  client.connected(1);
  deliver(client, ClientLayoutSnapshot{});
  const auto open = transport.last<OpenPane>();
  const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
  require(client.requestsPending(), "The fixture must retain its real canonical workspace request");
}

void hiddenStartupKeepsMetadataWithoutOpeningAPane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.setPresented(false);
  client.connected(1);
  deliver(client, ClientLayoutSnapshot{});
  require(client.ready() && !client.presented() && client.activeTab() == nullptr, "a hidden machine must connect for metadata without a presented workspace");
  require(transport.count(ClientTag::open_pane) == 0 && client.panes().empty(), "a hidden initial connection must defer its first pane");
  client.setPresented(true);
  require(transport.count(ClientTag::open_pane) == 1, "presenting the machine must open its deferred first pane once");
  client.setPresented(true);
  require(transport.count(ClientTag::open_pane) == 1, "repeated presentation must not duplicate the initial opening request");
}

void aHiddenRestoredLayoutOwnsItsDataUntilPresentation() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.setPresented(false);
  client.connected(1);
  constexpr std::uint64_t first_pane = 11;
  constexpr std::uint64_t focused_pane = 12;
  constexpr std::uint16_t sidebar_columns = 32;
  constexpr std::uint16_t split_ratio = PaneLayout::ratio_half;
  constexpr std::uint64_t restored_tab = 7;
  const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 4}, .tab_id = restored_tab};
  const std::array<ClientLayoutNode, 3> nodes{ClientLayoutSplit{.axis = ClientLayoutAxis::vertical, .ratio = split_ratio}, ClientLayoutPane{first_pane}, ClientLayoutPane{focused_pane}};
  const std::array tabs{ClientTabLayout{.location = location, .focused_pane = focused_pane, .fullscreen = false, .workspace_active = true, .nodes = nodes}};
  deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_visible = false, .sidebar_width = sidebar_columns, .workspace_list_collapsed = true, .active_tab = location, .tabs = tabs});
  deliver(client, PaneTitle{.pane_id = first_pane, .title = "overwrite the decoder storage"});
  require(client.activeTab() == nullptr && client.panes().empty() && transport.count(ClientTag::open_pane) == 0, "a hidden restored layout must retain owned layout data without constructing pane screens");
  client.setPresented(true);
  const auto opening = transport.last<OpenPane>();
  require(opening.target.kind == PaneTarget::Kind::pane && opening.target.id == focused_pane && !opening.launch, "presentation must reopen the remembered root before asking for its canonical tabs");
  deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = focused_pane, .location = location, .pane_generation = 1});
  require(client.activeTab()->layout.nodes().size() == 1, "the restored split must remain staged until canonical membership arrives");
  const std::array panes{PaneDescriptor{.pane_id = first_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = focused_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  finishSnapshots(client, transport, location, panes);
  require(client.activeTab() != nullptr && client.activeTab()->focused_pane == focused_pane, "deferred restoration must retain the original focused pane");
  require(!client.activeTab()->layout.nodes().empty(), "deferred restoration must retain layout nodes");
  const auto *split = std::get_if<ClientLayoutSplit>(&client.activeTab()->layout.nodes().front());
  require(split != nullptr && split->axis == ClientLayoutAxis::vertical && split->ratio == split_ratio, "deferred layout topology and ratio must survive decoder reuse");
  require(!client.configuration().sidebar_visible && client.workspaceListCollapsed(), "deferred restoration must retain the saved sidebar preferences");
}

void rapidReturnDoesNotDuplicateAnOpeningAlreadyInFlight() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.setPresented(false);
  client.setPresented(true);
  const auto openings = transport.count(ClientTag::open_pane);
  client.setPresented(false);
  client.setPresented(true);
  require(transport.count(ClientTag::open_pane) == openings, "rapid machine switching must retain the existing restoration request without opening the pane twice");
}

void hidingReleasesScreensAndReturningReopensTheFocusedPane() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  Transport transport;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    const auto location = client.activeTab()->location;
    client.toggleFullscreen();
    deliverSingleCell(client, {.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = 1}});
    const auto retained = memory.liveBytes();
    client.setPresented(false);
    require(client.ready() && !client.presented() && client.activeTab() == nullptr && client.panes().empty(), "hiding must retire the workspace and all pane-owned screen storage while retaining the connection");
    require(memory.liveBytes() < retained, "hiding must release allocator-owned pane and screen storage");
    require(transport.count(ClientTag::detach_pane) == 1 && transport.detaching.size() == 1, "hiding must release input ownership before detaching the pane exactly once");
    require(transport.count(ClientTag::close_pane) == 0 && transport.count(ClientTag::runtime_stop) == 0, "hiding must preserve the runtime's processes");
    require(!client.settlePresentation(), "completed departure must be idempotent");
    client.setPresented(true);
    const auto restore = transport.last<OpenPane>();
    require(restore.target.kind == PaneTarget::Kind::pane && restore.target.id == 1 && !restore.launch, "returning must reopen the remembered focused pane without launching a shell");
    deliver(client, PaneOpened{.request_id = restore.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
    const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
    finishSnapshots(client, transport, location, panes);
    require(client.activeTab() != nullptr && client.activeTab()->focused_pane == 1 && client.activeTab()->fullscreen, "returning must retain focus and fullscreen layout state");
  }

  require(memory.liveBytes() == 0, "presentation and restoration must release every session allocation on destruction");
}

void hidingWaitsForCanonicalSnapshotsBeforeDetaching() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.connected(1);
  deliver(client, ClientLayoutSnapshot{});
  const auto open = transport.last<OpenPane>();
  const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
  client.setPresented(false);
  require(client.activeTab() != nullptr && transport.count(ClientTag::detach_pane) == 0, "departure must wait for canonical tab and workspace requests already in flight");
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
  require(!client.settlePresentation() && transport.count(ClientTag::detach_pane) == 0, "a remaining workspace response must keep the departure pending");
  const std::array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
  require(client.settlePresentation() && client.panes().empty() && transport.count(ClientTag::detach_pane) == 1, "the last canonical response must allow the hidden workspace to retire");
}

void hidingWaitsForAnAttachmentAndHandlesItsLateReply() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto location = client.activeTab()->location;
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
  const auto attach = transport.last<OpenPane>();
  require(attach.target.kind == PaneTarget::Kind::pane && attach.target.id == 2, "the second visible pane must have an attachment request in flight");
  client.setPresented(false);
  require(!client.settlePresentation(), "an attachment request must keep departure pending");
  deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 2, .location = location, .pane_generation = 1});
  require(client.settlePresentation() && client.panes().empty(), "a late attachment reply must be retired after its request settles");
  require(transport.count(ClientTag::detach_pane) == 2, "every attached pane must detach when the machine is hidden");
}

void metadataDoesNotReattachAHiddenMachine() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto location = client.activeTab()->location;
  client.setPresented(false);
  const auto openings = transport.count(ClientTag::open_pane);
  const std::array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}, TabDescriptor{.tab_id = 2, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = location.workspace, .name = "updated", .tabs = tabs});
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
  require(client.activeTab() == nullptr && client.panes().empty() && transport.count(ClientTag::open_pane) == openings, "background workspace metadata must not reopen hidden panes");
}

void hiddenCompletionRemainsUnacknowledgedUntilPresentation() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openWithPendingWorkspaceSnapshot(client, transport);
  std::array entries{agentSnapshotEntry()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
  client.setPresented(false);
  entries.front().status = AgentStatus::done;
  deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
  require(client.activeTab() != nullptr && transport.count(ClientTag::acknowledge_agent) == 0, "a hidden machine awaiting departure must retain unseen completions even while its tab remains active");
  client.setPresented(true);
  require(transport.count(ClientTag::acknowledge_agent) == 1, "returning to the retained workspace must acknowledge its focused completion");
}

void failedSnapshotsDoNotPreventDeparture() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.connected(1);
  deliver(client, ClientLayoutSnapshot{});
  const auto open = transport.last<OpenPane>();
  const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
  const auto tab_request = transport.last<RequestTabSnapshot>();
  const auto workspace_request = transport.last<RequestWorkspaceSnapshot>();
  client.setPresented(false);
  deliver(client, RequestFailed{.request_id = tab_request.request_id, .code = FailureCode::tab_not_found, .message = "Tab is gone"});
  require(!client.settlePresentation(), "a failed tab snapshot must retire only its own pending request");
  deliver(client, RequestFailed{.request_id = workspace_request.request_id, .code = FailureCode::workspace_not_found, .message = "Workspace is gone"});
  require(client.settlePresentation() && client.panes().empty(), "failed snapshot requests must not permanently retain a hidden workspace");
}

void disconnectionReleasesAHiddenWorkspaceWithoutSendingDetaches() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openWithPendingWorkspaceSnapshot(client, transport);
  client.setPresented(false);
  client.disconnected();
  require(client.settlePresentation() && client.panes().empty() && client.activeTab() == nullptr, "a disconnected hidden machine must release its former screens after pending requests are cancelled");
  require(transport.count(ClientTag::detach_pane) == 0, "a disconnected machine must not queue detach messages for a dead transport");
}

void returningBeforeDepartureSettlesKeepsTheWorkspace() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openWithPendingWorkspaceSnapshot(client, transport);
  const auto location = client.activeTab()->location;
  client.setPresented(false);
  client.setPresented(true);
  const std::array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}};
  deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
  require(!client.settlePresentation() && client.activeTab() != nullptr && client.findPane(1) != nullptr, "returning before pending requests settle must cancel departure without dropping the workspace");
  require(transport.count(ClientTag::detach_pane) == 0, "cancelled departure must not detach its existing pane");
}

void aMissingRememberedPaneFallsBackToItsSourceWorkspaceOnce() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.setPresented(false);
  client.setPresented(true);
  const auto restore = transport.last<OpenPane>();
  deliver(client, RequestFailed{.request_id = restore.request_id, .code = FailureCode::pane_not_found, .message = "Remembered pane is gone"});
  const auto fallback = transport.last<OpenPane>();
  require(fallback.request_id != restore.request_id && fallback.target.kind == PaneTarget::Kind::workspace && fallback.target.id == 1, "a missing remembered pane must reopen its source workspace");
  const auto openings = transport.count(ClientTag::open_pane);
  deliver(client, RequestFailed{.request_id = fallback.request_id, .code = FailureCode::workspace_not_found, .message = "Workspace is gone"});
  require(transport.count(ClientTag::open_pane) == openings, "a failed fallback must not start an unbounded restoration loop");
}

void aPartialDetachCanRetryWithoutDroppingPendingScreens() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto location = client.activeTab()->location;
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
  const auto attach = transport.last<OpenPane>();
  deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 2, .location = location, .pane_generation = 1});
  transport.reject_detach_after = 1;
  bool rejected = false;
  try {
    client.setPresented(false);
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && client.panes().size() == 2 && client.activeTab() != nullptr, "a partial transport failure must retain all pane objects until departure can finish");
  require(transport.count(ClientTag::detach_pane) == 1, "only the successfully queued detach may be committed before retry");
  transport.reject_detach_after.reset();
  require(client.settlePresentation() && client.panes().empty(), "retrying the pending departure must finish releasing its screens");
  require(transport.count(ClientTag::detach_pane) == 2, "retry must detach only the pane whose earlier delivery failed");
}

}

int main() {
  try {
    hiddenStartupKeepsMetadataWithoutOpeningAPane();
    aHiddenRestoredLayoutOwnsItsDataUntilPresentation();
    rapidReturnDoesNotDuplicateAnOpeningAlreadyInFlight();
    hidingReleasesScreensAndReturningReopensTheFocusedPane();
    hidingWaitsForCanonicalSnapshotsBeforeDetaching();
    hidingWaitsForAnAttachmentAndHandlesItsLateReply();
    metadataDoesNotReattachAHiddenMachine();
    hiddenCompletionRemainsUnacknowledgedUntilPresentation();
    failedSnapshotsDoNotPreventDeparture();
    disconnectionReleasesAHiddenWorkspaceWithoutSendingDetaches();
    returningBeforeDepartureSettlesKeepsTheWorkspace();
    aMissingRememberedPaneFallsBackToItsSourceWorkspaceOnce();
    aPartialDetachCanRetryWithoutDroppingPendingScreens();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
