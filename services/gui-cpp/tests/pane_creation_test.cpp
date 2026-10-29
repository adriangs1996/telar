#include "allocation_gate.hpp"
#include "application/records.hpp"
#include "application/session.hpp"
#include "application/workbench_geometry.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "session_fixture.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <new>
#include <optional>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

const Tab<SystemAllocator> *tabIn(const Session<SystemAllocator, Transport> &client, TabLocation location) {
  for (const auto &tab : client.tabs()) {
    if (sameTab(tab->location, location)) {
      return tab.get();
    }
  }

  return nullptr;
}

void newTabsKeepTheWorkbenchSizeAfterAChildResize() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto workbench = client.focusedPane()->size;
  client.split(ClientLayoutAxis::horizontal);
  const auto split = transport.last<CreatePane>();
  deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
  auto child = workbench;
  child.cols /= 2;
  client.resize(1, child);
  client.resize(2, child);
  client.createTab();
  const auto request = transport.last<CreateTab>();
  require(request.size.cols == workbench.cols && request.size.rows == workbench.rows, "a new tab must use the whole workbench rather than the last resized child");
}

void splitRequestsStartAtTheirChildSize() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto parent = client.focusedPane()->size;
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  require(request.size.cols < parent.cols && request.size.rows == parent.rows - 2, "a horizontal split must launch with its child width rather than the parent's width");
  require(transport.last<PaneResize>().size.cols < parent.cols, "the source PTY must receive its provisional child size before process creation");
}

void splitRepliesWithoutAnIdentityRefreshTheRuntimeGeneration() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  const auto snapshots = transport.count(ClientTag::request_tab_snapshot);
  deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true});
  require(transport.count(ClientTag::request_tab_snapshot) == snapshots + 1, "a split reply without a runtime generation must request the authoritative pane descriptors");
  const auto refresh = transport.last<RequestTabSnapshot>();
  require(sameTab(refresh.location, request.location), "identity refresh must stay in the split's tab");
  const auto attachment = client.findPane(2)->attachment_generation;
  constexpr std::uint64_t runtime_generation = 7;
  const std::array<PaneDescriptor, 2> descriptors{{{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, {.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = runtime_generation}}};
  deliver(client, TabSnapshot{.request_id = refresh.request_id, .location = request.location, .panes = descriptors});
  require(client.findPane(2)->generation == runtime_generation && client.findPane(2)->attachment_generation == attachment, "runtime identity resolution must preserve the existing client attachment");
  require(client.focusedPane()->id == 2 && client.activeTab()->layout.nodes().size() == 3, "identity refresh must retain focus and the committed split tree");
}

void gridConversionPreservesPixelsAndRejectsInvalidGeometry() {
  constexpr double display_scale = 2;
  const TerminalGrid grid{.scale = display_scale};
  const auto width = default_terminal_size.cols * grid.cell_width_px / grid.scale;
  const auto height = default_terminal_size.rows * grid.cell_height_px / grid.scale;
  const auto exact = grid.fit(width, height);
  require(exact && exact->cols == default_terminal_size.cols && exact->rows == default_terminal_size.rows && exact->cell_width_px == default_terminal_size.cell_width_px && exact->cell_height_px == default_terminal_size.cell_height_px, "logical cell fitting must preserve the physical high-DPI dimensions");
  const auto below = grid.fit(std::nextafter(width, 0.0), height);
  require(below && below->cols == default_terminal_size.cols - 1, "a value immediately below a cell boundary must not round up");
  constexpr auto infinity = std::numeric_limits<double>::infinity();
  constexpr auto invalid_number = std::numeric_limits<double>::quiet_NaN();
  for (const auto invalid : std::array{0.0, -1.0, infinity, invalid_number}) {
    require(!grid.fit(invalid, height) && !grid.fit(width, invalid), "non-finite and non-positive extents must not produce terminal requests");
    auto invalid_grid = grid;
    invalid_grid.scale = invalid;
    require(!invalid_grid.fit(width, height), "an invalid display scale must not produce a terminal request");
  }

  const auto saturated = grid.fit(std::numeric_limits<double>::max(), std::numeric_limits<double>::max());
  require(saturated && saturated->cols == TerminalGrid::maximum_dimension && static_cast<std::size_t>(saturated->cols) * saturated->rows <= TerminalGrid::maximum_cells, "oversized dimensions must remain within the dimension and frame-cell budgets");
}

constexpr WorkbenchGeometry framed_geometry{.area = {.width = 1010, .height = 850}, .grid = {.cell_width_px = 20, .cell_height_px = 40, .scale = 2}, .layout_metrics = {.border = 1, .gap = 1}};

void aRejectedSplitRestoresAnUnframedSinglePane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  client.setWorkbenchGeometry(framed_geometry);
  openFirstPane(client, transport);
  const auto initial = transport.last<OpenPane>().size;
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::invalid_request, .message = "creation rejected"});
  const auto restored = transport.last<PaneResize>().size;
  require(restored.cols == initial.cols && restored.rows == initial.rows, "a rejected first split must restore the entire single-pane workbench without reserving a header or border");
}

void splitRequestsUseTheSameContentGeometryAsTheirViews() {
  struct SplitCase {
    ClientLayoutAxis axis;
    std::uint16_t columns;
    std::uint16_t rows;
  };

  constexpr auto cases = std::to_array<SplitCase>({
      {.axis = ClientLayoutAxis::horizontal, .columns = 48, .rows = 40},
      {.axis = ClientLayoutAxis::vertical, .columns = 99, .rows = 19},
  });
  for (const auto &entry : cases) {
    SystemAllocator memory;
    Transport transport;
    Session client{memory, transport};
    client.setWorkbenchGeometry(framed_geometry);
    openFirstPane(client, transport);
    const auto opened = transport.last<OpenPane>();
    constexpr TerminalSize initial_size{.cols = 101, .rows = 42, .cell_width_px = framed_geometry.grid.cell_width_px, .cell_height_px = framed_geometry.grid.cell_height_px};
    require(opened.size.cols == initial_size.cols && opened.size.rows == initial_size.rows, "first-pane launch must use the current workbench before a terminal delegate exists");
    const auto original_nodes = client.activeTab()->layout.nodes().size();
    const auto before = transport.sent.size();
    client.split(entry.axis);
    const auto request = transport.last<CreatePane>();
    require(request.size.cols == entry.columns && request.size.rows == entry.rows, "the child request must account for its split, gap, border and header");
    require(request.size.cell_width_px == framed_geometry.grid.cell_width_px && request.size.cell_height_px == framed_geometry.grid.cell_height_px && request.launch.cwd_source == 1, "split requests must preserve current physical cells and the exact launch source");
    require(transport.sent[before].front() == static_cast<Byte>(ClientTag::pane_resize) && transport.sent[before + 1].front() == static_cast<Byte>(ClientTag::create_pane), "provisional source resizing must precede process creation");
    require(client.activeTab()->layout.nodes().size() == original_nodes && client.focusedPane()->id == 1, "planning must preserve semantic membership and focus until confirmation");
    deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
    require(client.focusedPane()->id == 2 && client.findPane(2)->size.cols == entry.columns && client.findPane(2)->size.rows == entry.rows, "confirmation must adopt the planned size before a view can report another resize");
  }
}

void splitDeliveryFailuresRestoreTheSourceAndReleaseOwnership() {
  for (const bool reject_resize : std::array{false, true}) {
    SystemAllocator memory;
    Transport transport;
    Session client{memory, transport};
    openFirstPane(client, transport);
    transport.reject_create_pane = !reject_resize;
    transport.reject_next_pane_resize = reject_resize;
    bool rejected = false;
    try {
      client.split(ClientLayoutAxis::horizontal);
    } catch (const std::exception &) {
      rejected = true;
    }

    const auto restored = transport.last<PaneResize>();
    require(rejected && restored.pane_id == 1 && restored.size.cols == default_terminal_size.cols, "failed provisional resizing or creation must restore the original source size");
    require(client.activeTab()->layout.nodes().size() == 1 && client.focusedPane()->id == 1, "delivery failure must leave membership and focus unchanged");
    transport.reject_create_pane = false;
    client.split(ClientLayoutAxis::vertical);
    require(transport.count(ClientTag::create_pane) == 1, "a failed send must release the pending pane operation");
  }
}

void runtimeFailureRestoresCurrentGeometryAndBusyRequestsDoNotOverlap() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  const auto sent = transport.sent.size();
  client.split(ClientLayoutAxis::vertical);
  client.closePane(1);
  require(transport.sent.size() == sent, "a split must share one pending owner with other pane operations");
  auto enlarged = client.workbenchGeometry();
  enlarged.area.width *= 2;
  client.setWorkbenchGeometry(enlarged);
  deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::invalid_request, .message = "creation rejected"});
  require(transport.last<PaneResize>().size.cols == default_terminal_size.cols * 2, "runtime rejection must restore the current workbench rather than a stale captured size");
  client.split(ClientLayoutAxis::vertical);
  require(transport.count(ClientTag::create_pane) == 2, "runtime rejection must release the pane operation");
}

TabLocation openAnotherTab(Session<SystemAllocator, Transport> &client, const Transport &transport) {
  client.createTab();
  const auto request = transport.last<CreateTab>();
  const TabLocation location{.workspace = request.workspace, .tab_id = 2};
  deliver(client, TabCreated{.request_id = request.request_id, .location = location, .position = 1, .label = "other", .root_pane_id = 3, .pane_generation = 1});

  return location;
}

void lateSplitConfirmationPreservesTheActiveTabAndDuplicateOwnership() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  const auto other = openAnotherTab(client, transport);
  const PaneOpened confirmation{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1};
  deliver(client, confirmation);
  require(sameTab(client.activeTab()->location, other) && client.focusedPane()->id == 3, "an inactive split confirmation must not select its former tab");
  const auto *hidden = tabIn(client, request.location);
  require(hidden != nullptr && client.findPane(2) != nullptr && !client.findPane(2)->attached && hidden->layout.contains(2), "a hidden split must retain membership while releasing the runtime attachment");
  const auto detachments = transport.count(ClientTag::detach_pane);
  deliver(client, confirmation);
  require(transport.count(ClientTag::detach_pane) == detachments && client.focusedPane()->id == 3, "a duplicate confirmation must not detach a currently represented pane again");
}

void confirmationCannotRecreateARemovedTab() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.split(ClientLayoutAxis::horizontal);
  const auto request = transport.last<CreatePane>();
  const auto other = openAnotherTab(client, transport);
  deliver(client, TabClosed{.location = request.location});
  deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
  require(tabIn(client, request.location) == nullptr && client.findPane(2) == nullptr && sameTab(client.activeTab()->location, other), "a late split must not resurrect a closed tab or change the active tab");
  require(transport.last<DetachPane>().pane_id == 2, "an unrepresented created pane must release its attachment without killing its process");
}

void aVanishedSourceUsesTheSurvivingTabMembership() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.split(ClientLayoutAxis::horizontal);
  const auto first = transport.last<CreatePane>();
  deliver(client, PaneOpened{.request_id = first.request_id, .pane_id = 2, .location = first.location, .created = true, .pane_generation = 1});
  client.focusPane(1);
  client.split(ClientLayoutAxis::vertical);
  const auto next = transport.last<CreatePane>();
  deliver(client, PaneExited{.pane_id = 1, .kind = ExitKind::exited});
  deliver(client, PaneOpened{.request_id = next.request_id, .pane_id = 4, .location = next.location, .created = true, .pane_generation = 1});
  require(client.findPane(1) == nullptr && client.focusedPane()->id == 4 && client.activeTab()->layout.contains(2), "a confirmed pane must join the surviving tab when its original source has exited");
}

void anEmptyWorkbenchCannotCreateOrResizeProcesses() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  auto geometry = client.workbenchGeometry();
  geometry.area.width = 0;
  client.setWorkbenchGeometry(geometry);
  const auto before = transport.sent.size();
  client.split(ClientLayoutAxis::horizontal);
  require(transport.sent.size() == before, "an unavailable split must not send provisional resize or creation requests");
  bool rejected = false;
  try {
    client.createTab();
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected && transport.sent.size() == before, "a zero-sized workbench must reject creation before registering or sending a request");
}

std::size_t adoptSplitWithAllocationBudget(std::optional<std::size_t> budget) {
  SystemAllocator system;
  BudgetAllocator counted{system, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{counted};
  Transport transport;
  std::size_t allocations = 0;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    client.split(ClientLayoutAxis::horizontal);
    const auto request = transport.last<CreatePane>();
    const auto before = counted.allocations();
    memory.permit(budget);
    bool rejected = false;
    try {
      deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = request.location, .created = true, .pane_generation = 1});
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    allocations = counted.allocations() - before;
    memory.permit(std::nullopt);
    if (budget) {
      require(rejected && client.findPane(2) == nullptr && client.focusedPane()->id == 1 && client.activeTab()->layout.nodes().size() == 1, "a failed allocation must preserve the source and the semantic layout");
      require(transport.last<DetachPane>().pane_id == 2 && transport.last<PaneResize>().size.cols == default_terminal_size.cols, "a failed adoption must release the new attachment and restore the source PTY");
    } else {
      require(!rejected && client.focusedPane()->id == 2, "a complete allocation budget must adopt and focus the new pane");
    }
  }

  require(counted.liveBytes() == 0, "failed and successful pane adoption must release every injected allocation");

  return allocations;
}

void adoptionRecoversFromEveryAllocationFailure() {
  const auto allocations = adoptSplitWithAllocationBudget(std::nullopt);
  for (std::size_t permitted = 0; permitted < allocations; ++permitted) {
    static_cast<void>(adoptSplitWithAllocationBudget(permitted));
  }
}

void routedCommandsRejectBusyAndUnavailableCreation() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::pane_create};
  deliver(client, command);
  const auto split = transport.last<CreatePane>();
  require(transport.last<CompleteClientCommand>().status == ClientCommandStatus::admitted, "a requested pane must report admission");
  ++command.request_id;
  deliver(client, command);
  const auto busy = transport.last<CompleteClientCommand>();
  require(busy.status == ClientCommandStatus::failed && busy.text == "PaneCreationUnavailable", "a busy pane operation must fail rather than report admission without a request");
  command.action = ClientAction::pane_close;
  command.target_id = 1;
  ++command.request_id;
  deliver(client, command);
  require(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "closure must report failure while a split owns the pane operation");
  deliver(client, RequestFailed{.request_id = split.request_id, .code = FailureCode::invalid_request, .message = "rejected"});
  auto unavailable = client.workbenchGeometry();
  unavailable.area.width = 0;
  client.setWorkbenchGeometry(unavailable);
  command.action = ClientAction::pane_split;
  command.text = "horizontal";
  ++command.request_id;
  deliver(client, command);
  require(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "a split without usable geometry must not report admission");
}

void routedTabsRejectAnExistingTabOperation() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.createTab();
  const ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::tab_create};
  deliver(client, command);
  const auto reply = transport.last<CompleteClientCommand>();
  require(reply.status == ClientCommandStatus::failed && reply.text == "ClientBusy" && transport.count(ClientTag::create_tab) == 1, "a busy tab operation must fail without reporting admission or launching another process");
}

void fractionalScaleKeepsACompletePhysicalCell() {
  constexpr double scale = 1.25;
  constexpr double width = 880;
  constexpr double height = 760;
  constexpr TerminalSize expected{.cols = 100, .rows = 50, .cell_width_px = 11, .cell_height_px = 19};
  const TerminalGrid grid{.cell_width_px = expected.cell_width_px, .cell_height_px = expected.cell_height_px, .scale = scale};
  const auto fitted = grid.fit(width, height);
  require(fitted && fitted->cols == expected.cols && fitted->rows == expected.rows, "fractional scaling must retain every complete physical cell instead of losing one to division rounding");
}

}

int main() {
  try {
    newTabsKeepTheWorkbenchSizeAfterAChildResize();
    splitRequestsStartAtTheirChildSize();
    splitRepliesWithoutAnIdentityRefreshTheRuntimeGeneration();
    gridConversionPreservesPixelsAndRejectsInvalidGeometry();
    aRejectedSplitRestoresAnUnframedSinglePane();
    splitRequestsUseTheSameContentGeometryAsTheirViews();
    splitDeliveryFailuresRestoreTheSourceAndReleaseOwnership();
    runtimeFailureRestoresCurrentGeometryAndBusyRequestsDoNotOverlap();
    lateSplitConfirmationPreservesTheActiveTabAndDuplicateOwnership();
    confirmationCannotRecreateARemovedTab();
    aVanishedSourceUsesTheSurvivingTabMembership();
    anEmptyWorkbenchCannotCreateOrResizeProcesses();
    adoptionRecoversFromEveryAllocationFailure();
    routedCommandsRejectBusyAndUnavailableCreation();
    routedTabsRejectAnExistingTabOperation();
    fractionalScaleKeepsACompletePhysicalCell();
    std::cout << "gui-pane-creation: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-pane-creation: " << error.what() << '\n';

    return 1;
  }
}
