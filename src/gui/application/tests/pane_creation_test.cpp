#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/protocol/clients.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <string_view>

import telar.testing;
import telar.gui.tests.allocation_gate;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.wire.layout;
import telar.wire.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;

  const Tab<Memory>* tabIn(const application::Session& client, TabLocation location) {
    for (const auto& tab : client.tabs) {
      if (sameTab(tab->location, location)) {
        return &tab.get();
      }
    }

    return nullptr;
  }

  void newTabsKeepTheWorkbenchSizeAfterAChildResize() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto workbench = client.focusedPane()->size;

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    auto child = workbench;

    child.cols /= 2;
    client.resize(1, child);
    client.resize(2, child);
    application::workbench::createTab(client);
    const auto request = transport.last<CreateTab>();

    check(request.size.cols == workbench.cols && request.size.rows == workbench.rows, "a new tab must use the whole workbench rather than the last resized child");
  }

  void splitRequestsStartAtTheirChildSize() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto parent = client.focusedPane()->size;

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();

    check(request.size.cols < parent.cols && request.size.rows == parent.rows, "a horizontal split must launch with its child width rather than the parent's width");
    check(transport.last<PaneResize>().size.cols < parent.cols, "the source PTY must receive its provisional child size before process creation");
  }

  void splitRepliesWithoutAnIdentityRefreshTheRuntimeGeneration() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();
    const auto snapshots = transport.count(ClientTag::request_tab_snapshot);

    deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true});
    check(transport.count(ClientTag::request_tab_snapshot) == snapshots + 1, "a split reply without a runtime generation must request the authoritative pane descriptors");
    const auto refresh = transport.last<RequestTabSnapshot>();

    check(sameTab(refresh.location, request.location), "identity refresh must stay in the split's tab");
    const auto attachment = client.findPane(2)->attachment_generation;
    constexpr std::uint64_t runtime_generation = 7;
    const ds::Array<PaneDescriptor, 2> descriptors{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, {.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = runtime_generation}}};

    deliver(client, TabSnapshot{.request_id = refresh.request_id, .location = request.location, .panes = descriptors});
    check(client.findPane(2)->generation == runtime_generation && client.findPane(2)->attachment_generation == attachment, "runtime identity resolution must preserve the existing client attachment");
    check(client.focusedPane()->id == 2 && client.activeTab()->layout.nodes().size() == 3, "identity refresh must retain focus and the committed split tree");
  }

  void gridConversionPreservesPixelsAndRejectsInvalidGeometry() {
    constexpr double display_scale = 2;
    const TerminalGrid grid{.scale = display_scale};
    const auto width = default_terminal_size.cols * grid.cell_width_px / grid.scale;
    const auto height = default_terminal_size.rows * grid.cell_height_px / grid.scale;
    const auto exact = grid.fit(width, height);

    check(exact && exact->cols == default_terminal_size.cols && exact->rows == default_terminal_size.rows && exact->cell_width_px == default_terminal_size.cell_width_px && exact->cell_height_px == default_terminal_size.cell_height_px, "logical cell fitting must preserve the physical high-DPI dimensions");
    const auto below = grid.fit(std::nextafter(width, 0.0), height);

    check(below && below->cols == default_terminal_size.cols - 1, "a value immediately below a cell boundary must not round up");
    constexpr auto infinity = std::numeric_limits<double>::infinity();
    constexpr auto invalid_number = std::numeric_limits<double>::quiet_NaN();

    for (const auto invalid : ds::Array{0.0, -1.0, infinity, invalid_number}) {
      check(!grid.fit(invalid, height) && !grid.fit(width, invalid), "non-finite and non-positive extents must not produce terminal requests");
      auto invalid_grid = grid;

      invalid_grid.scale = invalid;
      check(!invalid_grid.fit(width, height), "an invalid display scale must not produce a terminal request");
    }

    const auto saturated = grid.fit(std::numeric_limits<double>::max(), std::numeric_limits<double>::max());

    check(saturated && saturated->cols == TerminalGrid::maximum_dimension && static_cast<std::size_t>(saturated->cols) * saturated->rows <= TerminalGrid::maximum_cells, "oversized dimensions must remain within the dimension and frame-cell budgets");
  }

  constexpr WorkbenchGeometry framed_geometry{.area = {.width = 1010, .height = 850}, .grid = {.cell_width_px = 20, .cell_height_px = 40, .scale = 2}, .layout_metrics = {.border = 1, .gap = 1}};

  void aRejectedSplitRestoresTheSinglePane() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    application::workbench::setGeometry(client, framed_geometry);
    openFirstPane(client, transport);
    const auto initial = transport.last<OpenPane>().size;

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();

    deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::invalid_request, .message = "creation rejected"});
    const auto restored = transport.last<PaneResize>().size;

    check(restored.cols == initial.cols && restored.rows == initial.rows, "a rejected first split must restore the single pane to its launch size");
  }

  void splitRequestsUseTheSameContentGeometryAsTheirViews() {
    struct SplitCase {
      ClientLayoutAxis axis;
      std::uint16_t columns;
      std::uint16_t rows;
    };

    constexpr ds::Array cases{
        SplitCase{.axis = ClientLayoutAxis::horizontal, .columns = 48, .rows = 41},
        SplitCase{.axis = ClientLayoutAxis::vertical, .columns = 99, .rows = 20},
    };

    for (const auto& entry : cases) {
      SystemAllocator memory;
      Transport transport;
      TestSession client{memory, transport};

      application::workbench::setGeometry(client, framed_geometry);
      openFirstPane(client, transport);
      const auto opened = transport.last<OpenPane>();
      constexpr TerminalSize initial_size{.cols = 99, .rows = 41, .cell_width_px = framed_geometry.grid.cell_width_px, .cell_height_px = framed_geometry.grid.cell_height_px};

      check(opened.size.cols == initial_size.cols && opened.size.rows == initial_size.rows, "first-pane launch must use the framed workbench content before a terminal delegate exists");
      const auto original_nodes = client.activeTab()->layout.nodes().size();
      const auto before = transport.sent.size();

      application::workbench::split(client, entry.axis);
      const auto request = transport.last<CreatePane>();

      check(request.size.cols == entry.columns && request.size.rows == entry.rows, "the child request must account for its split, gap, border and header");
      check(request.size.cell_width_px == framed_geometry.grid.cell_width_px && request.size.cell_height_px == framed_geometry.grid.cell_height_px && request.launch.cwd_source == 1, "split requests must preserve current physical cells and the exact launch source");
      check(transport.sent[before].front() == static_cast<Byte>(ClientTag::pane_resize) && transport.sent[before + 1].front() == static_cast<Byte>(ClientTag::create_pane), "provisional source resizing must precede process creation");
      check(client.activeTab()->layout.nodes().size() == original_nodes && client.focusedPane()->id == 1, "planning must preserve semantic membership and focus until confirmation");
      deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
      check(client.focusedPane()->id == 2 && client.findPane(2)->size.cols == entry.columns && client.findPane(2)->size.rows == entry.rows, "confirmation must adopt the planned size before a view can report another resize");
    }
  }

  void splitDeliveryFailuresRestoreTheSourceAndReleaseOwnership() {
    for (const bool reject_resize : ds::Array{false, true}) {
      SystemAllocator memory;
      Transport transport;
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      const auto original = client.focusedPane()->size;

      transport.reject_create_pane = !reject_resize;
      transport.reject_next_pane_resize = reject_resize;
      bool rejected = false;

      try {
        application::workbench::split(client, ClientLayoutAxis::horizontal);
      } catch (const std::exception&) {
        rejected = true;
      }

      const auto restored = transport.last<PaneResize>();

      check(rejected && restored.pane_id == 1 && restored.size.cols == original.cols, "failed provisional resizing or creation must restore the original source size");
      check(client.activeTab()->layout.nodes().size() == 1 && client.focusedPane()->id == 1, "delivery failure must leave membership and focus unchanged");
      transport.reject_create_pane = false;
      application::workbench::split(client, ClientLayoutAxis::vertical);
      check(transport.count(ClientTag::create_pane) == 1, "a failed send must release the pending pane operation");
    }
  }

  void runtimeFailureRestoresCurrentGeometryAndBusyRequestsDoNotOverlap() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();
    const auto sent = transport.sent.size();

    application::workbench::split(client, ClientLayoutAxis::vertical);
    application::workbench::closePane(client, 1);
    check(transport.sent.size() == sent, "a split must share one pending owner with other pane operations");
    auto enlarged = application::workbench::geometry(client);

    enlarged.area.width *= 2;
    application::workbench::setGeometry(client, enlarged);
    deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::invalid_request, .message = "creation rejected"});
    check(transport.last<PaneResize>().size.cols == enlarged.launchSize()->cols, "runtime rejection must restore the current workbench rather than a stale captured size");
    application::workbench::split(client, ClientLayoutAxis::vertical);
    check(transport.count(ClientTag::create_pane) == 2, "runtime rejection must release the pane operation");
  }

  TabLocation openAnotherTab(application::Session& client, const Transport& transport) {
    application::workbench::createTab(client);
    const auto request = transport.last<CreateTab>();
    const TabLocation location{.workspace = request.workspace, .tab_id = 2};

    deliver(client, TabCreated{.request_id = request.request_id, .location = location, .position = 1, .label = "other", .root_pane_id = 3, .pane_generation = 1});

    return location;
  }

  void lateSplitConfirmationPreservesTheActiveTabAndDuplicateOwnership() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();
    const auto other = openAnotherTab(client, transport);
    const PaneOpened confirmation{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1};

    deliver(client, confirmation);
    check(sameTab(client.activeTab()->location, other) && client.focusedPane()->id == 3, "an inactive split confirmation must not select its former tab");
    const auto* hidden = tabIn(client, request.location);

    check(hidden != nullptr && client.findPane(2) != nullptr && !client.findPane(2)->attached && hidden->layout.contains(2), "a hidden split must retain membership while releasing the runtime attachment");
    const auto detachments = transport.count(ClientTag::detach_pane);

    deliver(client, confirmation);
    check(transport.count(ClientTag::detach_pane) == detachments && client.focusedPane()->id == 3, "a duplicate confirmation must not detach a currently represented pane again");
  }

  void confirmationCannotRecreateARemovedTab() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();
    const auto other = openAnotherTab(client, transport);

    deliver(client, TabClosed{.location = request.location});
    deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
    check(tabIn(client, request.location) == nullptr && client.findPane(2) == nullptr && sameTab(client.activeTab()->location, other), "a late split must not resurrect a closed tab or change the active tab");
    check(transport.last<DetachPane>().pane_id == 2, "an unrepresented created pane must release its attachment without killing its process");
  }

  void aVanishedSourceUsesTheSurvivingTabMembership() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto first = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = first.request_id, .pane_id = 2, .location = first.location, .created = true, .pane_generation = 1});
    application::workbench::focusPane(client, 1);
    application::workbench::split(client, ClientLayoutAxis::vertical);
    const auto next = transport.last<CreatePane>();

    deliver(client, PaneExited{.pane_id = 1, .kind = ExitKind::exited});
    deliver(client, PaneOpened{.request_id = next.request_id, .pane_id = 4, .location = next.location, .created = true, .pane_generation = 1});
    check(client.findPane(1) == nullptr && client.focusedPane()->id == 4 && client.activeTab()->layout.contains(2), "a confirmed pane must join the surviving tab when its original source has exited");
  }

  void anEmptyWorkbenchCannotCreateOrResizeProcesses() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    auto geometry = application::workbench::geometry(client);

    geometry.area.width = 0;
    application::workbench::setGeometry(client, geometry);
    const auto before = transport.sent.size();

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    check(transport.sent.size() == before, "an unavailable split must not send provisional resize or creation requests");
    bool rejected = false;

    try {
      application::workbench::createTab(client);
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected && transport.sent.size() == before, "a zero-sized workbench must reject creation before registering or sending a request");
  }

  std::size_t adoptSplitWithAllocationBudget(ds::Option<std::size_t> budget) {
    SystemAllocator system;
    BudgetAllocator counted{system, std::numeric_limits<std::size_t>::max()};
    AllocationGate gate{counted};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;
    Transport transport;
    std::size_t allocations = 0;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      application::workbench::split(client, ClientLayoutAxis::horizontal);
      const auto request = transport.last<CreatePane>();
      const auto before = counted.allocations();

      gate.permit(budget);
      bool rejected = false;

      try {
        deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      allocations = counted.allocations() - before;
      gate.permit(ds::none);
      if (budget) {
        check(rejected && client.findPane(2) == nullptr && client.focusedPane()->id == 1 && client.activeTab()->layout.nodes().size() == 1, "a failed allocation must preserve the source and the semantic layout");
        check(transport.last<DetachPane>().pane_id == 2 && transport.last<PaneResize>().size.cols == application::workbench::geometry(client).launchSize()->cols, "a failed adoption must release the new attachment and restore the source PTY");
      } else {
        check(!rejected && client.focusedPane()->id == 2, "a complete allocation budget must adopt and focus the new pane");
      }
    }

    check(counted.liveBytes() == 0, "failed and successful pane adoption must release every injected allocation");

    return allocations;
  }

  void adoptionRecoversFromEveryAllocationFailure() {
    const auto allocations = adoptSplitWithAllocationBudget(ds::none);

    for (std::size_t permitted = 0; permitted < allocations; ++permitted) {
      static_cast<void>(adoptSplitWithAllocationBudget(permitted));
    }
  }

  void routedCommandsRejectBusyAndUnavailableCreation() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::pane_create};

    deliver(client, command);
    const auto split = transport.last<CreatePane>();

    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::admitted, "a requested pane must report admission");
    ++command.request_id;
    deliver(client, command);
    const auto busy = transport.last<CompleteClientCommand>();

    check(busy.status == ClientCommandStatus::failed && busy.text == "PaneCreationUnavailable", "a busy pane operation must fail rather than report admission without a request");
    command.action = ClientAction::pane_close;
    command.target_id = 1;
    ++command.request_id;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "closure must report failure while a split owns the pane operation");
    deliver(client, RequestFailed{.request_id = split.request_id, .code = FailureCode::invalid_request, .message = "rejected"});
    auto unavailable = application::workbench::geometry(client);

    unavailable.area.width = 0;
    application::workbench::setGeometry(client, unavailable);
    command.action = ClientAction::pane_split;
    command.text = "horizontal";
    ++command.request_id;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "a split without usable geometry must not report admission");
  }

  void routedTabsRejectAnExistingTabOperation() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::createTab(client);
    const ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::tab_create};

    deliver(client, command);
    const auto reply = transport.last<CompleteClientCommand>();

    check(reply.status == ClientCommandStatus::failed && reply.text == "ClientBusy" && transport.count(ClientTag::create_tab) == 1, "a busy tab operation must fail without reporting admission or launching another process");
  }

  void fractionalScaleKeepsACompletePhysicalCell() {
    constexpr double scale = 1.25;
    constexpr double width = 880;
    constexpr double height = 760;
    constexpr TerminalSize expected{.cols = 100, .rows = 50, .cell_width_px = 11, .cell_height_px = 19};
    const TerminalGrid grid{.cell_width_px = expected.cell_width_px, .cell_height_px = expected.cell_height_px, .scale = scale};
    const auto fitted = grid.fit(width, height);

    check(fitted && fitted->cols == expected.cols && fitted->rows == expected.rows, "fractional scaling must retain every complete physical cell instead of losing one to division rounding");
  }

  const telar::testing::Case case_new_tabs_keep_the_workbench_size_after_a_child_resize{"pane_creation.new_tabs_keep_the_workbench_size_after_a_child_resize", newTabsKeepTheWorkbenchSizeAfterAChildResize};
  const telar::testing::Case case_split_requests_start_at_their_child_size{"pane_creation.split_requests_start_at_their_child_size", splitRequestsStartAtTheirChildSize};
  const telar::testing::Case case_split_replies_without_an_identity_refresh_the_runtime_generation{"pane_creation.split_replies_without_an_identity_refresh_the_runtime_generation", splitRepliesWithoutAnIdentityRefreshTheRuntimeGeneration};
  const telar::testing::Case case_grid_conversion_preserves_pixels_and_rejects_invalid_geometry{"pane_creation.grid_conversion_preserves_pixels_and_rejects_invalid_geometry", gridConversionPreservesPixelsAndRejectsInvalidGeometry};
  const telar::testing::Case case_a_rejected_split_restores_the_single_pane{"pane_creation.a_rejected_split_restores_the_single_pane", aRejectedSplitRestoresTheSinglePane};
  const telar::testing::Case case_split_requests_use_the_same_content_geometry_as_their_views{"pane_creation.split_requests_use_the_same_content_geometry_as_their_views", splitRequestsUseTheSameContentGeometryAsTheirViews};
  const telar::testing::Case case_split_delivery_failures_restore_the_source_and_release_ownership{"pane_creation.split_delivery_failures_restore_the_source_and_release_ownership", splitDeliveryFailuresRestoreTheSourceAndReleaseOwnership};
  const telar::testing::Case case_runtime_failure_restores_current_geometry_and_busy_requests_do_not_overlap{"pane_creation.runtime_failure_restores_current_geometry_and_busy_requests_do_not_overlap", runtimeFailureRestoresCurrentGeometryAndBusyRequestsDoNotOverlap};
  const telar::testing::Case case_late_split_confirmation_preserves_the_active_tab_and_duplicate_ownership{"pane_creation.late_split_confirmation_preserves_the_active_tab_and_duplicate_ownership", lateSplitConfirmationPreservesTheActiveTabAndDuplicateOwnership};
  const telar::testing::Case case_confirmation_cannot_recreate_a_removed_tab{"pane_creation.confirmation_cannot_recreate_a_removed_tab", confirmationCannotRecreateARemovedTab};
  const telar::testing::Case case_a_vanished_source_uses_the_surviving_tab_membership{"pane_creation.a_vanished_source_uses_the_surviving_tab_membership", aVanishedSourceUsesTheSurvivingTabMembership};
  const telar::testing::Case case_an_empty_workbench_cannot_create_or_resize_processes{"pane_creation.an_empty_workbench_cannot_create_or_resize_processes", anEmptyWorkbenchCannotCreateOrResizeProcesses};
  const telar::testing::Case case_adoption_recovers_from_every_allocation_failure{"pane_creation.adoption_recovers_from_every_allocation_failure", adoptionRecoversFromEveryAllocationFailure};
  const telar::testing::Case case_routed_commands_reject_busy_and_unavailable_creation{"pane_creation.routed_commands_reject_busy_and_unavailable_creation", routedCommandsRejectBusyAndUnavailableCreation};
  const telar::testing::Case case_routed_tabs_reject_an_existing_tab_operation{"pane_creation.routed_tabs_reject_an_existing_tab_operation", routedTabsRejectAnExistingTabOperation};
  const telar::testing::Case case_fractional_scale_keeps_a_complete_physical_cell{"pane_creation.fractional_scale_keeps_a_complete_physical_cell", fractionalScaleKeepsACompletePhysicalCell};

}
