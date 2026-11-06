#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "allocation_gate.hpp"
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
#include <new>
#include <string>
#include <type_traits>
#include <vector>

#include "core/memory.hpp"


import telar.gui.application.session;
import telar.gui.application.workspace_replica;
import telar.gui.core.unicode_scalar;
import telar.gui.peek.screen;
import telar.gui.presentation.suggestion_labels;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

constexpr PeekTarget target{.agent = {.pane_id = 9, .pane_generation = 3}, .session = {1}};
constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};
constexpr std::uint64_t worktree_id = 31;

AgentSnapshotEntry agent() {
  return {.pane_id = target.agent.pane_id, .pane_generation = target.agent.pane_generation, .location = location, .pane_index = 1, .session_id = target.session, .workspace_label = "Other", .session_title = "Owned agent", .title_source = AgentTitleSource::agent, .title_state = AgentTitleState::ready, .provider = AgentProvider::codex, .provider_name = "codex", .status = AgentStatus::working, .sequence = 1};
}

struct PeekTransport {
  Transport recorded;
  bool reject = false;
  bool reject_open = false;

  template <typename Message>
  void send(const Message &message) {
    if constexpr (std::is_same_v<Message, ReadPane> || std::is_same_v<Message, InterruptAgent>) {
      if (reject) {
        throw EncodingError{"Peek delivery rejected"};
      }
    }

    if constexpr (std::is_same_v<Message, OpenPane>) {
      if (reject_open && message.target.kind == PaneTarget::Kind::pane && message.target.id == target.agent.pane_id) {
        throw EncodingError{"Workspace target transport is full"};
      }
    }

    recorded.send(message);
  }
};

void commandsAndVisibleTailPreserveOriginalText() {
  constexpr std::array cases{
      std::pair{"", PeekCommand::open}, std::pair{" \t/open\t", PeekCommand::open}, std::pair{" /stop ", PeekCommand::stop}, std::pair{"\t/diff", PeekCommand::diff}, std::pair{"/Stop", PeekCommand::message}, std::pair{"/stop now", PeekCommand::message}, std::pair{"\n/stop", PeekCommand::message},
  };
  for (const auto &[text, command] : cases) {
    require(PeekInput::command(text) == command, "peek slash words retain exact case and only trim spaces and tabs");
  }

  using Screen = PeekScreen<SystemAllocator>;
  constexpr std::uint16_t two_rows = 2;
  require(Screen::lastLines("one\ntwo\nthree \r\n\t", two_rows) == "two\nthree", "peek clips its recent lines from the oldest visible row and trims only the tail");
  require(Screen::lastLines("one\n\nthree", two_rows) == "\nthree", "empty interior rows retain their visual positions");
  require(Screen::lastLines("text", 0).empty(), "a peek without screen rows must expose no pane text");
}

void retainedScreenOwnsItsReadAndUsesBoundedInjectedMemory() {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    PeekScreen screen{memory};
    const auto baseline = budget.allocations();
    screen.show(target);
    constexpr std::uint64_t first_request = 40;
    const auto request = screen.request(first_request);
    require(request && request->source == PaneTextSource::recent && request->rows == PeekLimits::rows && request->pane_generation == target.agent.pane_generation, "peek reads recent rows with the complete source pane identity");
    require(!screen.request(first_request + 1) && budget.allocations() == baseline, "opening and duplicate-read admission must not allocate");
    std::string text(PeekLimits::text_bytes + 1, 'x');
    constexpr std::string_view symbol = "\xf0\x9f\x8c\x8d";
    text.replace(0, symbol.size(), symbol);
    memory.permit(0);
    bool refused = false;
    try {
      static_cast<void>(screen.store({.request_id = first_request, .pane_id = target.agent.pane_id, .text = text, .exit_code = {}}));
    } catch (const std::bad_alloc &) {
      refused = true;
    }

    require(refused && screen.text().empty() && screen.target() && !screen.reading(), "allocation failure keeps the source identity and releases read admission for a later retry");
    memory.permit(std::nullopt);
    const auto retry = screen.request(first_request + 1);
    if (!retry) {
      throw std::runtime_error{"A failed text allocation must admit a fresh retry request"};
    }

    const auto dropped = screen.store({.request_id = retry.value().request_id, .pane_id = target.agent.pane_id, .text = text, .exit_code = {}});
    require(dropped && *dropped == symbol.size() && screen.text().size() == text.size() - symbol.size(), "a bounded peek drops a complete leading UTF-8 character at its tail boundary");
    const auto copied = std::string{screen.text()};
    text.assign(text.size(), 'z');
    require(screen.text() == copied, "peek text must outlive decoder storage reuse");
    const auto allocations = budget.allocations();
    memory.permit(0);
    const auto next = screen.request(first_request + 2);
    if (!next) {
      throw std::runtime_error{"A completed read must admit a later refresh"};
    }

    require(screen.store({.request_id = next.value().request_id, .pane_id = target.agent.pane_id, .text = copied, .exit_code = {}}) == 0 && budget.allocations() == allocations, "steady-state recent reads reuse their injected storage");
    screen.close();
    screen.show(target);
    const auto current = screen.request(first_request + 3);
    if (!current) {
      throw std::runtime_error{"A reopened peek must admit its own read"};
    }

    require(!screen.store({.request_id = first_request, .pane_id = target.agent.pane_id, .text = "old", .exit_code = {}}) && screen.reading(), "a retired reply cannot complete a later peek's read");
    require(!screen.fail(first_request) && screen.fail(current.value().request_id) && !screen.reading(), "failed reads release only their own request ownership");
  }

  require(budget.liveBytes() == 0, "peek buffers must release all injected memory");
}

void rejectedTransportReleasesOnlyItsOwnAdmission() {
  SystemAllocator memory;
  PeekTransport transport;
  Session client{memory, transport};
  openFirstPane(client, transport.recorded);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  transport.reject = true;
  bool refused = false;
  try {
    static_cast<void>(client.openPeek(target));
  } catch (const EncodingError &) {
    refused = true;
  }

  require(refused && !client.peek().target() && !client.requestsPending(), "a rejected initial read must retire its unopened peek without retaining a correlation");
  transport.reject = false;
  require(client.openPeek(target), "a later accepted read remains available");
  transport.reject = true;
  refused = false;
  try {
    static_cast<void>(client.submitPeek("/stop"));
  } catch (const EncodingError &) {
    refused = true;
  }

  require(refused && client.peek().target() && client.requestsPending(), "a rejected stop must retain the existing read while releasing its own action correlation");
  const auto read = transport.recorded.last<ReadPane>();
  deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Recent rows", .exit_code = {}});
  require(!client.requestsPending(), "the surviving read must release its own correlation when its reply arrives");
  transport.reject = false;
  require(client.submitPeek("/stop") && transport.recorded.count(ClientTag::interrupt_agent) == 1, "retrying a rejected action admits exactly one interrupt");
}

void peekRowsUseSaturatingOriginalCellCoordinates() {
  constexpr CellRectangle host{.x = std::numeric_limits<std::uint16_t>::max(), .y = std::numeric_limits<std::uint16_t>::max(), .width = 100, .height = 30};
  const auto geometry = PeekGeometry::measure(host);
  require(geometry.bounds.x == host.x && geometry.bounds.y == host.y && geometry.field.y == host.y && geometry.footer.y == host.y, "peek modal and row offsets must saturate instead of wrapping near the cell coordinate limit");
  require(geometry.screen.height == geometry.bounds.height - PeekGeometry::chrome_rows - 2, "peek screen rows must reserve border and original chrome rows");
  constexpr CellRectangle narrow{.width = 3, .height = 3};
  const auto tiny = PeekGeometry::measure(narrow);
  require(tiny.facts.empty() && tiny.field.empty(), "a modal with less than four inner rows must keep only its border and title");
}

void snapshotsRefreshMetadataWithoutAttachingThePeekedPane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  const auto openings = transport.count(ClientTag::open_pane);
  require(client.openPeek(target), "a live agent may be inspected without selecting its tab");
  const auto read = transport.last<ReadPane>();
  deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
  require(transport.count(ClientTag::read_pane) == 1, "snapshots coalesce while the same peek read is in flight");
  require(deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Owned recent text", .exit_code = {}}) == Change::peek && client.peek().text() == "Owned recent text", "a recent pane reply updates only peek presentation");
  require(client.focusedPane()->id == 1 && client.findPane(target.agent.pane_id) == nullptr && transport.count(ClientTag::open_pane) == openings, "a peek must retain the current tab and create no terminal screen or attachment");
  auto wrong = target;
  ++wrong.session.front();
  require(!client.openPeek(wrong) && client.peek().text() == "Owned recent text", "an invalid replacement cannot erase a live peek");
  deliver(client, AgentSnapshot{.revision = 3, .entries = agents});
  const auto refresh = transport.last<ReadPane>();
  require(refresh.request_id != read.request_id, "a later accepted snapshot asks for fresh recent rows");
  ++agents.front().session_id.front();
  deliver(client, AgentSnapshot{.revision = 4, .entries = agents});
  require(!client.peek().target() && !client.submitPeek("/stop"), "reused pane and generation values cannot retain a retired agent session");
  require(deliver(client, PaneText{.request_id = refresh.request_id, .pane_id = read.pane_id, .text = "Retired data", .exit_code = {}}) == Change::none && client.peek().text().empty(), "a retired session's delayed pane text must stay invisible");
}

void peekMessagesAndInterruptsKeepTheOriginalProtocol() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target) && client.submitPeek(" \tPlease continue \t"), "a peek may submit its field directly to the owned agent");
  const auto message = transport.last<SendPaneText>();
  require(message.pane_id == target.agent.pane_id && message.pane_generation == target.agent.pane_generation && message.mode == PaneTextMode::prompt && message.text == "Please continue" && !message.sender, "peek messages preserve prompt delivery and trim only the field edges");
  require(transport.count(ClientTag::pane_input) == 0 && !client.peek().target(), "peek prompt submission must not type into the focused local pane");
  const auto read = transport.last<ReadPane>();
  require(deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Closed read", .exit_code = {}}) == Change::none, "closing the field must retain and safely retire a later read reply");
  deliver(client, RequestCompleted{.request_id = message.request_id});
  require(!client.requestsPending() && client.openPeek(target) && client.submitPeek("/stop"), "an interrupt has its own releasable action correlation");
  const auto interrupt = transport.last<InterruptAgent>();
  require(interrupt.pane_id == target.agent.pane_id && interrupt.pane_generation == target.agent.pane_generation, "peek stop must address the original agent generation");
  const auto stopped_read = transport.last<ReadPane>();
  require(deliver(client, RequestFailed{.request_id = stopped_read.request_id, .code = FailureCode::pane_not_found, .message = "Read retired"}) == Change::none && client.error().empty(), "a read rejected after its peek closes must release quietly");
  deliver(client, RequestCompleted{.request_id = interrupt.request_id});
  require(client.openPeek(target), "a completed action leaves later peeks available");
  client.setPresented(false);
  require(!client.peek().target() && !client.submitPeek("Ignored") && !client.openPeek(target), "a hidden machine must discard peek interaction ownership");
}

void diffLaunchQuotesItsBranchAsAnArgumentAndWaitsForHandoff() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  const std::array worktrees{WorktreeListEntry{.worktree = worktree_id, .source = 1, .workspace = location.workspace.id, .path = "/project/checkout", .branch = "feature;touch injected"}};
  deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target), "a task-backed agent may be inspected");
  const auto read = transport.last<ReadPane>();
  deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Task rows", .exit_code = {}});
  require(client.submitPeek("/diff"), "a task-backed peek may launch its diff command");
  const auto launch = transport.last<LaunchWorktree>();
  constexpr TerminalSize original_size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};
  require(launch.worktree == worktree_id && launch.label == "diff" && launch.size.cols == original_size.cols && launch.size.rows == original_size.rows && launch.size.cell_width_px == original_size.cell_width_px && launch.size.cell_height_px == original_size.cell_height_px && launch.launch.cwd == worktrees.front().path, "peek diffs preserve task ownership and the original terminal size");
  constexpr std::size_t diff_argument_count = 5;
  constexpr std::size_t script_index = 2;
  require(launch.launch.arguments.size() == diff_argument_count && launch.launch.arguments.back() == worktrees.front().branch && !launch.launch.arguments[script_index].contains(worktrees.front().branch), "a branch must travel as one argument rather than shell script text");
  constexpr std::uint64_t diff_pane = 77;
  deliver(client, PaneOpened{.request_id = launch.request_id, .pane_id = diff_pane, .location = location, .created = true, .pane_generation = 1});
  const auto open = transport.last<OpenPane>();
  require(open.target.kind == PaneTarget::Kind::pane && open.target.id == diff_pane && client.findPane(diff_pane) == nullptr, "a launched diff must await the normal canonical pane handoff instead of constructing an incomplete screen");
}

void openingTaskPeekDetachesBeforeItsCanonicalPaneHandoff() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target), "a task agent must admit its read");
  const auto read = transport.last<ReadPane>();
  deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Task", .exit_code = {}});
  const auto first = transport.sent.size();
  require(client.submitPeek("/open"), "the task peek must close after handing off its source");
  require(transport.count(ClientTag::detach_pane) == 1 && transport.detaching == std::vector<std::uint64_t>{1}, "the current workspace must release its input and attachment before entering another");
  const auto messages = std::span{transport.sent}.subspan(first);
  const auto detach = std::ranges::find_if(messages, [](const auto &bytes) {
    return bytes.front() == static_cast<Byte>(ClientTag::detach_pane);
  });
  const auto opening = std::ranges::find_if(messages, [](const auto &bytes) {
    return bytes.front() == static_cast<Byte>(ClientTag::open_pane);
  });
  require(detach < opening && opening != messages.end(), "the runtime must see the departure before the target attachment");
  require(client.activeTab() == nullptr && client.panes().empty(), "screens must retire after the complete handoff is queued, awaiting a canonical root");
  const auto request = transport.last<OpenPane>();
  require(request.target.kind == PaneTarget::Kind::pane && request.target.id == target.agent.pane_id && !request.launch, "a task visit must reopen an existing pane without a new process");
  deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = target.agent.pane_id, .location = location, .pane_generation = target.agent.pane_generation});
  require(client.focusedPane() != nullptr && client.focusedPane()->id == target.agent.pane_id && client.focusedPane()->attached && sameTab(client.activeTab()->location, location), "the canonical reply must activate only the requested task pane and workspace");
}

void aBusyTaskPeekOpenClosesWithoutLeavingItsCurrentWorkspace() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target), "a task peek read must remain tracked");
  const auto read = transport.last<ReadPane>();
  const auto openings = transport.count(ClientTag::open_pane);
  require(client.submitPeek("/open") && !client.peek().target(), "a busy open still closes its peek as the original does");
  require(transport.count(ClientTag::open_pane) == openings && transport.count(ClientTag::detach_pane) == 0 && client.focusedPane()->id == 1 && client.focusedPane()->attached, "an outstanding canonical reply must fence workspace departure");
  deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Late read", .exit_code = {}});
  require(!client.requestsPending(), "the closed peek's late reply must release its original correlation");
}

void aMissingTaskPaneRetriesItsWorkspaceOnlyOnce() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.focusAgent(target.agent.pane_id, target.agent.pane_generation), "the known agent must admit navigation");
  const auto request = transport.last<OpenPane>();
  deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::pane_not_found, .message = "Task pane gone"});
  const auto fallback = transport.last<OpenPane>();
  require(fallback.request_id != request.request_id && fallback.target.kind == PaneTarget::Kind::workspace && fallback.target.id == location.workspace.id && !fallback.launch, "a disappeared agent pane must fall back once to its authoritative workspace");
  const auto openings = transport.count(ClientTag::open_pane);
  deliver(client, RequestFailed{.request_id = fallback.request_id, .code = FailureCode::workspace_not_found, .message = "Task workspace gone"});
  require(transport.count(ClientTag::open_pane) == openings && !client.requestsPending(), "a failed workspace fallback must not start an unbounded open loop");
}

void aRejectedTaskOpenRestoresItsDepartingAttachment() {
  SystemAllocator memory;
  PeekTransport transport;
  Session client{memory, transport};
  openFirstPane(client, transport.recorded);
  const auto source = client.activeTab()->location;
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  transport.reject_open = true;
  bool rejected = false;
  try {
    static_cast<void>(client.focusAgent(target.agent.pane_id, target.agent.pane_generation));
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && client.activeTab() != nullptr && sameTab(client.activeTab()->location, source) && client.findPane(1) != nullptr && client.findPane(target.agent.pane_id) == nullptr, "rejected target delivery must retain the old projection and its owned screens");
  require(transport.recorded.count(ClientTag::detach_pane) == 1, "the fixture must exercise rejection after an accepted departure");
  const auto repair = transport.recorded.last<OpenPane>();
  require(repair.target.kind == PaneTarget::Kind::pane && repair.target.id == 1 && client.findPane(1)->attaching, "accepted detaches must be repaired through a fresh correlated attachment");
  deliver(client, PaneOpened{.request_id = repair.request_id, .pane_id = 1, .location = source, .pane_generation = 1});
  require(client.focusedPane()->id == 1 && client.focusedPane()->attached && !client.requestsPending(), "the source's canonical repair must restore its original usable pane");
}

void aPartialTaskDepartureRepairsOnlyItsAcceptedDetaches() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const auto source = client.activeTab()->location;
  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}, PaneDescriptor{.pane_id = 2, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  deliver(client, TabSnapshot{.request_id = 1, .location = source, .panes = panes});
  const auto attachment = transport.last<OpenPane>();
  deliver(client, PaneOpened{.request_id = attachment.request_id, .pane_id = 2, .location = source, .pane_generation = 1});
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  transport.reject_detach_after = 1;
  bool rejected = false;
  try {
    static_cast<void>(client.focusAgent(target.agent.pane_id, target.agent.pane_generation));
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && client.panes().size() == panes.size() && sameTab(client.activeTab()->location, source), "partial departure must retain the complete previous projection");
  require(transport.count(ClientTag::detach_pane) == 1 && client.findPane(2)->attached, "an unaccepted detach must leave its original attachment committed");
  const auto repair = transport.last<OpenPane>();
  require(repair.target.id == 1 && client.findPane(1)->attaching, "only the successfully detached pane must request repair");
  deliver(client, PaneOpened{.request_id = repair.request_id, .pane_id = 1, .location = source, .pane_generation = 1});
  require(client.findPane(1)->attached && client.findPane(2)->attached && !client.requestsPending(), "canonical repair must leave both previous panes usable");
}

void aDiffArrivalWithPendingPeekReadKeepsItsCurrentWorkspace() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  const std::array worktrees{WorktreeListEntry{.worktree = worktree_id, .source = 1, .workspace = location.workspace.id, .path = "/project/checkout", .branch = "worktree/task"}};
  deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target), "the busy diff fixture must keep its real peek read pending");
  const auto read = transport.last<ReadPane>();
  require(client.submitPeek("/diff"), "a diff may launch before its retained read finishes");
  const auto launch = transport.last<LaunchWorktree>();
  const auto openings = transport.count(ClientTag::open_pane);
  constexpr std::uint64_t diff_pane = 77;
  deliver(client, PaneOpened{.request_id = launch.request_id, .pane_id = diff_pane, .location = location, .pane_generation = 1});
  require(transport.count(ClientTag::open_pane) == openings && transport.count(ClientTag::detach_pane) == 0 && client.focusedPane()->id == 1 && client.focusedPane()->attached, "a pending canonical read must fence automatic navigation to a launched diff");
  deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Closed read", .exit_code = {}});
  require(!client.requestsPending() && transport.count(ClientTag::open_pane) == openings && client.findPane(diff_pane) == nullptr, "a retired read must not start a delayed handoff that the original ignored");
}

void peekReadFailuresRetryAndRejectedActionsNotifyTheirPane() {
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const std::array agents{agent()};
  deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
  require(client.openPeek(target), "a live peek must admit its initial read");
  const auto read = transport.last<ReadPane>();
  require(deliver(client, RequestFailed{.request_id = read.request_id, .code = FailureCode::pane_not_found, .message = "Read rejected"}) == Change::none && !client.peek().reading() && client.peek().target(), "a failed recent read must quietly release ownership while keeping the open peek");
  require(client.error().empty() && client.notifications().items().empty() && !client.requestsPending(), "a recent-read failure must not turn into an unrelated diagnostic or notification");
  deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
  const auto retry = transport.last<ReadPane>();
  require(retry.request_id != read.request_id, "the next accepted agent snapshot retries a failed read");
  deliver(client, PaneText{.request_id = retry.request_id, .pane_id = retry.pane_id, .text = "Recent reply", .exit_code = {}});
  require(client.submitPeek("Please continue"), "a peek may hand off its field and close before the action reply");
  const auto action = transport.last<SendPaneText>();
  constexpr std::string_view refusal = "the pane has the focus in an attached window";
  require(deliver(client, RequestFailed{.request_id = action.request_id, .code = FailureCode::pane_focused, .message = refusal}) == Change::notification, "a refused peek action must publish the original failure notification");
  require(client.notifications().items().size() == 1 && !client.requestsPending(), "a refusal must retain one notice and release the action correlation");
  const auto &notice = client.notifications().items().front();
  constexpr std::uint64_t original_duration_ns = 7'000'000'000;
  require(notice.level == NotificationLevel::failure && notice.title.view() == "The agent did not take it" && notice.message.view() == refusal && notice.target.kind == NotificationTarget::Kind::pane && notice.target.id == target.agent.pane_id, "the failure card must retain the original text and inspected pane target");
  require(notice.expires_at_ns - notice.transition_updated_ns == original_duration_ns + NotificationItem::transition_duration_ns, "peek action failures retain their original seven-second lifetime");
}

}

int main() {
  try {
    commandsAndVisibleTailPreserveOriginalText();
    peekRowsUseSaturatingOriginalCellCoordinates();
    retainedScreenOwnsItsReadAndUsesBoundedInjectedMemory();
    rejectedTransportReleasesOnlyItsOwnAdmission();
    snapshotsRefreshMetadataWithoutAttachingThePeekedPane();
    peekMessagesAndInterruptsKeepTheOriginalProtocol();
    diffLaunchQuotesItsBranchAsAnArgumentAndWaitsForHandoff();
    openingTaskPeekDetachesBeforeItsCanonicalPaneHandoff();
    aBusyTaskPeekOpenClosesWithoutLeavingItsCurrentWorkspace();
    aMissingTaskPaneRetriesItsWorkspaceOnlyOnce();
    aRejectedTaskOpenRestoresItsDepartingAttachment();
    aPartialTaskDepartureRepairsOnlyItsAcceptedDetaches();
    aDiffArrivalWithPendingPeekReadKeepsItsCurrentWorkspace();
    peekReadFailuresRetryAndRejectedActionsNotifyTheirPane();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
