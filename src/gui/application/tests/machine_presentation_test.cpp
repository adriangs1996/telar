#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <variant>

import telar.testing;
import telar.gui.tests.agent_fixture;
import telar.gui.application.tests.session_fixture;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.wire.agents;
import telar.wire.layout;
import telar.wire.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;

  template <typename Client>
  void finishSnapshots(Client& client, Transport& transport, TabLocation location, std::span<const PaneDescriptor> panes) {
    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
    const ds::Array tabs{TabDescriptor{.tab_id = location.tab_id, .pane_count = static_cast<std::uint16_t>(panes.size())}};

    deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
  }

  template <typename Client>
  void openWithPendingWorkspaceSnapshot(Client& client, Transport& transport) {
    client.connected(1);
    deliver(client, ClientLayoutSnapshot{});
    const auto open = transport.last<OpenPane>();
    const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

    deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
    const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
    check(client.requestsPending(), "The fixture must retain its real canonical workspace request");
  }

  void hiddenStartupKeepsMetadataWithoutOpeningAPane() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    client.setPresented(false);
    client.connected(1);
    deliver(client, ClientLayoutSnapshot{});
    check(client.ready() && !client.presented() && client.activeTab() == nullptr, "a hidden machine must connect for metadata without a presented workspace");
    check(transport.count(ClientTag::open_pane) == 0 && client.panes().empty(), "a hidden initial connection must defer its first pane");
    client.setPresented(true);
    check(transport.count(ClientTag::open_pane) == 1, "presenting the machine must open its deferred first pane once");
    client.setPresented(true);
    check(transport.count(ClientTag::open_pane) == 1, "repeated presentation must not duplicate the initial opening request");
  }

  void aHiddenRestoredLayoutOwnsItsDataUntilPresentation() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    client.setPresented(false);
    client.connected(1);
    constexpr std::uint64_t first_pane = 11;
    constexpr std::uint64_t focused_pane = 12;
    constexpr std::uint16_t sidebar_columns = 32;
    constexpr std::uint16_t split_ratio = PaneLayout::ratio_half;
    constexpr std::uint64_t restored_tab = 7;
    const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 4}, .tab_id = restored_tab};
    const ds::Array<ClientLayoutNode, 3> nodes{ClientLayoutSplit{.axis = ClientLayoutAxis::vertical, .ratio = split_ratio}, ClientLayoutPane{first_pane}, ClientLayoutPane{focused_pane}};
    const ds::Array tabs{ClientTabLayout{.location = location, .focused_pane = focused_pane, .fullscreen = false, .workspace_active = true, .nodes = nodes}};

    deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_visible = false, .sidebar_width = sidebar_columns, .workspace_list_collapsed = true, .active_tab = location, .tabs = tabs});
    deliver(client, PaneTitle{.pane_id = first_pane, .title = "overwrite the decoder storage"});
    check(client.activeTab() == nullptr && client.panes().empty() && transport.count(ClientTag::open_pane) == 0, "a hidden restored layout must retain owned layout data without constructing pane screens");
    client.setPresented(true);
    const auto opening = transport.last<OpenPane>();

    check(opening.target.kind == PaneTarget::Kind::pane && opening.target.id == focused_pane && !opening.launch, "presentation must reopen the remembered root before asking for its canonical tabs");
    deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = focused_pane, .location = location, .pane_generation = 1});
    check(client.activeTab()->layout.nodes().size() == 1, "the restored split must remain staged until canonical membership arrives");
    const ds::Array panes{PaneDescriptor{.pane_id = first_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = focused_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    finishSnapshots(client, transport, location, panes);
    check(client.activeTab() != nullptr && client.activeTab()->focused_pane == focused_pane, "deferred restoration must retain the original focused pane");
    check(!client.activeTab()->layout.nodes().empty(), "deferred restoration must retain layout nodes");
    const auto* split = std::get_if<ClientLayoutSplit>(&client.activeTab()->layout.nodes().front());

    check(split != nullptr && split->axis == ClientLayoutAxis::vertical && split->ratio == split_ratio, "deferred layout topology and ratio must survive decoder reuse");
    check(!client.configuration().sidebar_visible && client.workspaceListCollapsed(), "deferred restoration must retain the saved sidebar preferences");
  }

  void rapidReturnDoesNotDuplicateAnOpeningAlreadyInFlight() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    client.setPresented(false);
    client.setPresented(true);
    const auto openings = transport.count(ClientTag::open_pane);

    client.setPresented(false);
    client.setPresented(true);
    check(transport.count(ClientTag::open_pane) == openings, "rapid machine switching must retain the existing restoration request without opening the pane twice");
  }

  void hidingReleasesScreensAndReturningReopensTheFocusedPane() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Transport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      const auto location = client.activeTab()->location;

      application::workbench::toggleFullscreen(client);
      deliverSingleCell(client, {.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = 1}});
      const auto retained = budget.liveBytes();

      client.setPresented(false);
      check(client.ready() && !client.presented() && client.activeTab() == nullptr && client.panes().empty(), "hiding must retire the workspace and all pane-owned screen storage while retaining the connection");
      check(budget.liveBytes() < retained, "hiding must release allocator-owned pane and screen storage");
      check(transport.count(ClientTag::detach_pane) == 1 && transport.detaching.size() == 1, "hiding must release input ownership before detaching the pane exactly once");
      check(transport.count(ClientTag::close_pane) == 0 && transport.count(ClientTag::runtime_stop) == 0, "hiding must preserve the runtime's processes");
      check(!client.settlePresentation(), "completed departure must be idempotent");
      client.setPresented(true);
      const auto restore = transport.last<OpenPane>();

      check(restore.target.kind == PaneTarget::Kind::pane && restore.target.id == 1 && !restore.launch, "returning must reopen the remembered focused pane without launching a shell");
      deliver(client, PaneOpened{.request_id = restore.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
      const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

      finishSnapshots(client, transport, location, panes);
      check(client.activeTab() != nullptr && client.activeTab()->focused_pane == 1 && client.activeTab()->fullscreen, "returning must retain focus and fullscreen layout state");
    }

    check(budget.liveBytes() == 0, "presentation and restoration must release every session allocation on destruction");
  }

  void hidingWaitsForCanonicalSnapshotsBeforeDetaching() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    client.connected(1);
    deliver(client, ClientLayoutSnapshot{});
    const auto open = transport.last<OpenPane>();
    const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

    deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
    client.setPresented(false);
    check(client.activeTab() != nullptr && transport.count(ClientTag::detach_pane) == 0, "departure must wait for canonical tab and workspace requests already in flight");
    const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
    check(!client.settlePresentation() && transport.count(ClientTag::detach_pane) == 0, "a remaining workspace response must keep the departure pending");
    const ds::Array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}};

    deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
    check(client.settlePresentation() && client.panes().empty() && transport.count(ClientTag::detach_pane) == 1, "the last canonical response must allow the hidden workspace to retire");
  }

  void hidingWaitsForAnAttachmentAndHandlesItsLateReply() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto location = client.activeTab()->location;
    const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
    const auto attach = transport.last<OpenPane>();

    check(attach.target.kind == PaneTarget::Kind::pane && attach.target.id == 2, "the second visible pane must have an attachment request in flight");
    client.setPresented(false);
    check(!client.settlePresentation(), "an attachment request must keep departure pending");
    deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 2, .location = location, .pane_generation = 1});
    check(client.settlePresentation() && client.panes().empty(), "a late attachment reply must be retired after its request settles");
    check(transport.count(ClientTag::detach_pane) == 2, "every attached pane must detach when the machine is hidden");
  }

  void metadataDoesNotReattachAHiddenMachine() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto location = client.activeTab()->location;

    client.setPresented(false);
    const auto openings = transport.count(ClientTag::open_pane);
    const ds::Array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}, TabDescriptor{.tab_id = 2, .pane_count = 1}};

    deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = location.workspace, .name = "updated", .tabs = tabs});
    const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
    check(client.activeTab() == nullptr && client.panes().empty() && transport.count(ClientTag::open_pane) == openings, "background workspace metadata must not reopen hidden panes");
  }

  void hiddenCompletionRemainsUnacknowledgedUntilPresentation() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openWithPendingWorkspaceSnapshot(client, transport);
    ds::Array entries{agentSnapshotEntry()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = entries});
    client.setPresented(false);
    entries.atMut(0).status = AgentStatus::done;
    deliver(client, AgentSnapshot{.revision = 2, .entries = entries});
    check(client.activeTab() != nullptr && transport.count(ClientTag::acknowledge_agent) == 0, "a hidden machine awaiting departure must retain unseen completions even while its tab remains active");
    client.setPresented(true);
    check(transport.count(ClientTag::acknowledge_agent) == 1, "returning to the retained workspace must acknowledge its focused completion");
  }

  void failedSnapshotsDoNotPreventDeparture() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    client.connected(1);
    deliver(client, ClientLayoutSnapshot{});
    const auto open = transport.last<OpenPane>();
    const TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};

    deliver(client, PaneOpened{.request_id = open.request_id, .pane_id = 1, .location = location, .pane_generation = 1});
    const auto tab_request = transport.last<RequestTabSnapshot>();
    const auto workspace_request = transport.last<RequestWorkspaceSnapshot>();

    client.setPresented(false);
    deliver(client, RequestFailed{.request_id = tab_request.request_id, .code = FailureCode::tab_not_found, .message = "Tab is gone"});
    check(!client.settlePresentation(), "a failed tab snapshot must retire only its own pending request");
    deliver(client, RequestFailed{.request_id = workspace_request.request_id, .code = FailureCode::workspace_not_found, .message = "Workspace is gone"});
    check(client.settlePresentation() && client.panes().empty(), "failed snapshot requests must not permanently retain a hidden workspace");
  }

  void disconnectionReleasesAHiddenWorkspaceWithoutSendingDetaches() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openWithPendingWorkspaceSnapshot(client, transport);
    client.setPresented(false);
    client.disconnected();
    check(client.settlePresentation() && client.panes().empty() && client.activeTab() == nullptr, "a disconnected hidden machine must release its former screens after pending requests are cancelled");
    check(transport.count(ClientTag::detach_pane) == 0, "a disconnected machine must not queue detach messages for a dead transport");
  }

  void returningBeforeDepartureSettlesKeepsTheWorkspace() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openWithPendingWorkspaceSnapshot(client, transport);
    const auto location = client.activeTab()->location;

    client.setPresented(false);
    client.setPresented(true);
    const ds::Array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}};

    deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "project", .tabs = tabs});
    check(!client.settlePresentation() && client.activeTab() != nullptr && client.findPane(1) != nullptr, "returning before pending requests settle must cancel departure without dropping the workspace");
    check(transport.count(ClientTag::detach_pane) == 0, "cancelled departure must not detach its existing pane");
  }

  void aMissingRememberedPaneFallsBackToItsSourceWorkspaceOnce() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    client.setPresented(false);
    client.setPresented(true);
    const auto restore = transport.last<OpenPane>();

    deliver(client, RequestFailed{.request_id = restore.request_id, .code = FailureCode::pane_not_found, .message = "Remembered pane is gone"});
    const auto fallback = transport.last<OpenPane>();

    check(fallback.request_id != restore.request_id && fallback.target.kind == PaneTarget::Kind::workspace && fallback.target.id == 1, "a missing remembered pane must reopen its source workspace");
    const auto openings = transport.count(ClientTag::open_pane);

    deliver(client, RequestFailed{.request_id = fallback.request_id, .code = FailureCode::workspace_not_found, .message = "Workspace is gone"});
    check(transport.count(ClientTag::open_pane) == openings, "a failed fallback must not start an unbounded restoration loop");
  }

  void aPartialDetachCanRetryWithoutDroppingPendingScreens() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto location = client.activeTab()->location;
    const ds::Array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = 1, .location = location, .panes = panes});
    const auto attach = transport.last<OpenPane>();

    deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 2, .location = location, .pane_generation = 1});
    transport.reject_detach_after = 1;
    bool rejected = false;

    try {
      client.setPresented(false);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && client.panes().size() == 2 && client.activeTab() != nullptr, "a partial transport failure must retain all pane objects until departure can finish");
    check(transport.count(ClientTag::detach_pane) == 1, "only the successfully queued detach may be committed before retry");
    transport.reject_detach_after.reset();
    check(client.settlePresentation() && client.panes().empty(), "retrying the pending departure must finish releasing its screens");
    check(transport.count(ClientTag::detach_pane) == 2, "retry must detach only the pane whose earlier delivery failed");
  }

  const telar::testing::Case case_hidden_startup_keeps_metadata_without_opening_a_pane{"machine_presentation.hidden_startup_keeps_metadata_without_opening_a_pane", hiddenStartupKeepsMetadataWithoutOpeningAPane};
  const telar::testing::Case case_a_hidden_restored_layout_owns_its_data_until_presentation{"machine_presentation.a_hidden_restored_layout_owns_its_data_until_presentation", aHiddenRestoredLayoutOwnsItsDataUntilPresentation};
  const telar::testing::Case case_rapid_return_does_not_duplicate_an_opening_already_in_flight{"machine_presentation.rapid_return_does_not_duplicate_an_opening_already_in_flight", rapidReturnDoesNotDuplicateAnOpeningAlreadyInFlight};
  const telar::testing::Case case_hiding_releases_screens_and_returning_reopens_the_focused_pane{"machine_presentation.hiding_releases_screens_and_returning_reopens_the_focused_pane", hidingReleasesScreensAndReturningReopensTheFocusedPane};
  const telar::testing::Case case_hiding_waits_for_canonical_snapshots_before_detaching{"machine_presentation.hiding_waits_for_canonical_snapshots_before_detaching", hidingWaitsForCanonicalSnapshotsBeforeDetaching};
  const telar::testing::Case case_hiding_waits_for_an_attachment_and_handles_its_late_reply{"machine_presentation.hiding_waits_for_an_attachment_and_handles_its_late_reply", hidingWaitsForAnAttachmentAndHandlesItsLateReply};
  const telar::testing::Case case_metadata_does_not_reattach_a_hidden_machine{"machine_presentation.metadata_does_not_reattach_a_hidden_machine", metadataDoesNotReattachAHiddenMachine};
  const telar::testing::Case case_hidden_completion_remains_unacknowledged_until_presentation{"machine_presentation.hidden_completion_remains_unacknowledged_until_presentation", hiddenCompletionRemainsUnacknowledgedUntilPresentation};
  const telar::testing::Case case_failed_snapshots_do_not_prevent_departure{"machine_presentation.failed_snapshots_do_not_prevent_departure", failedSnapshotsDoNotPreventDeparture};
  const telar::testing::Case case_disconnection_releases_a_hidden_workspace_without_sending_detaches{"machine_presentation.disconnection_releases_a_hidden_workspace_without_sending_detaches", disconnectionReleasesAHiddenWorkspaceWithoutSendingDetaches};
  const telar::testing::Case case_returning_before_departure_settles_keeps_the_workspace{"machine_presentation.returning_before_departure_settles_keeps_the_workspace", returningBeforeDepartureSettlesKeepsTheWorkspace};
  const telar::testing::Case case_a_missing_remembered_pane_falls_back_to_its_source_workspace_once{"machine_presentation.a_missing_remembered_pane_falls_back_to_its_source_workspace_once", aMissingRememberedPaneFallsBackToItsSourceWorkspaceOnce};
  const telar::testing::Case case_a_partial_detach_can_retry_without_dropping_pending_screens{"machine_presentation.a_partial_detach_can_retry_without_dropping_pending_screens", aPartialDetachCanRetryWithoutDroppingPendingScreens};

}
