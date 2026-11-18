#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import telar.testing;
import telar.gui.tests.allocation_gate;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.features.peek;
import telar.gui.features.notifications;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::notifications;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;
  using features::peek::PeekCommand;
  using features::peek::PeekGeometry;
  using features::peek::PeekLimits;
  using features::peek::PeekTarget;

  constexpr PeekTarget target{.agent = {.pane_id = 9, .pane_generation = 3}, .session = {1}};
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};
  constexpr std::uint64_t worktree_id = 31;

  AgentSnapshotEntry agent() {
    return {.pane_id = target.agent.pane_id, .pane_generation = target.agent.pane_generation, .location = location, .pane_index = 1, .session_id = target.session, .workspace_label = "Other", .session_title = "Owned agent", .title_source = AgentTitleSource::agent, .title_state = AgentTitleState::ready, .provider = AgentProvider::codex, .provider_name = "codex", .status = AgentStatus::working, .sequence = 1};
  }

  struct PeekTransport final : application::RuntimeTransport {
    Transport recorded;
    bool reject = false;
    bool reject_open = false;

    std::span<Byte> buffer(std::size_t size) override {
      return recorded.buffer(size);
    }

    void send(std::span<const Byte> message) override {
      const auto tag = static_cast<ClientTag>(message.front());
      if ((tag == MessageSchema<ReadPane>::tag || tag == MessageSchema<InterruptAgent>::tag) && reject) {
        throw EncodingError{"Peek delivery rejected"};
      }

      if (tag == MessageSchema<OpenPane>::tag && reject_open) {
        std::array<Byte, Transport::decode_capacity> storage{};
        DecodeStorage decoded{storage};
        const auto open = Codec::decode<OpenPane>(message, decoded);
        if (open.target.kind == PaneTarget::Kind::pane && open.target.id == target.agent.pane_id) {
          throw EncodingError{"Workspace target transport is full"};
        }
      }

      recorded.send(message);
    }
  };

  void commandsAndVisibleTailPreserveOriginalText() {
    constexpr std::array cases{
        std::pair{"", PeekCommand::open},
        std::pair{" \t/open\t", PeekCommand::open},
        std::pair{" /stop ", PeekCommand::stop},
        std::pair{"\t/diff", PeekCommand::diff},
        std::pair{"/Stop", PeekCommand::message},
        std::pair{"/stop now", PeekCommand::message},
        std::pair{"\n/stop", PeekCommand::message},
    };

    for (const auto& [text, command] : cases) {
      check(features::peek::submit(text).command == command, "peek slash words retain exact case and only trim spaces and tabs");
    }

    constexpr std::uint16_t two_rows = 2;

    check(features::peek::lastLines("one\ntwo\nthree \r\n\t", two_rows) == "two\nthree", "peek clips its recent lines from the oldest visible row and trims only the tail");
    check(features::peek::lastLines("one\n\nthree", two_rows) == "\nthree", "empty interior rows retain their visual positions");
    check(features::peek::lastLines("text", 0).empty(), "a peek without screen rows must expose no pane text");
  }

  void retainedScreenOwnsItsReadAndUsesBoundedInjectedMemory() {
    SystemAllocator upstream;
    BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
    AllocationGate memory{budget};
    telar::MemoryAdapter adapter{memory};

    {
      features::peek::State screen{adapter};
      const auto baseline = budget.allocations();

      features::peek::open(screen, target);
      constexpr std::uint64_t first_request = 40;
      const auto request = features::peek::read(screen, first_request);

      check(request && request->source == PaneTextSource::recent && request->rows == PeekLimits::rows && request->pane_generation == target.agent.pane_generation, "peek reads recent rows with the complete source pane identity");
      check(!features::peek::read(screen, first_request + 1) && budget.allocations() == baseline, "opening and duplicate-read admission must not allocate");
      std::string text(PeekLimits::text_bytes + 1, 'x');
      constexpr std::string_view symbol = "\xf0\x9f\x8c\x8d";

      text.replace(0, symbol.size(), symbol);
      memory.permit(0);
      bool refused = false;

      try {
        static_cast<void>(features::peek::receive(screen, {.request_id = first_request, .pane_id = target.agent.pane_id, .text = text, .exit_code = {}}));
      } catch (const std::bad_alloc&) {
        refused = true;
      }

      check(refused && features::peek::text(screen).empty() && features::peek::target(screen) && !features::peek::reading(screen), "allocation failure keeps the source identity and releases read admission for a later retry");
      memory.permit(ds::none);
      const auto retry = features::peek::read(screen, first_request + 1);
      if (!retry) {
        throw std::runtime_error{"A failed text allocation must admit a fresh retry request"};
      }

      const auto dropped = features::peek::receive(screen, {.request_id = retry.get().request_id, .pane_id = target.agent.pane_id, .text = text, .exit_code = {}});

      check(dropped && *dropped == symbol.size() && features::peek::text(screen).size() == text.size() - symbol.size(), "a bounded peek drops a complete leading UTF-8 character at its tail boundary");
      const auto copied = std::string{features::peek::text(screen)};

      text.assign(text.size(), 'z');
      check(features::peek::text(screen) == copied, "peek text must outlive decoder storage reuse");
      const auto allocations = budget.allocations();

      memory.permit(0);
      const auto next = features::peek::read(screen, first_request + 2);
      if (!next) {
        throw std::runtime_error{"A completed read must admit a later refresh"};
      }

      check(features::peek::receive(screen, {.request_id = next.get().request_id, .pane_id = target.agent.pane_id, .text = copied, .exit_code = {}}) == 0 && budget.allocations() == allocations, "steady-state recent reads reuse their injected storage");
      features::peek::close(screen);
      features::peek::open(screen, target);
      const auto current = features::peek::read(screen, first_request + 3);
      if (!current) {
        throw std::runtime_error{"A reopened peek must admit its own read"};
      }

      check(!features::peek::receive(screen, {.request_id = first_request, .pane_id = target.agent.pane_id, .text = "old", .exit_code = {}}) && features::peek::reading(screen), "a retired reply cannot complete a later peek's read");
      check(!features::peek::fail(screen, first_request) && features::peek::fail(screen, current.get().request_id) && !features::peek::reading(screen), "failed reads release only their own request ownership");
    }

    check(budget.liveBytes() == 0, "peek buffers must release all injected memory");
  }

  void rejectedTransportReleasesOnlyItsOwnAdmission() {
    SystemAllocator memory;
    PeekTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport.recorded);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    transport.reject = true;
    bool refused = false;

    try {
      static_cast<void>(application::peek::open(client, target));
    } catch (const EncodingError&) {
      refused = true;
    }

    check(refused && !application::peek::target(client) && !client.requestsPending(), "a rejected initial read must retire its unopened peek without retaining a correlation");
    transport.reject = false;
    check(application::peek::open(client, target), "a later accepted read remains available");
    transport.reject = true;
    refused = false;
    try {
      static_cast<void>(application::peek::submit(client, "/stop"));
    } catch (const EncodingError&) {
      refused = true;
    }

    check(refused && application::peek::target(client) && client.requestsPending(), "a rejected stop must retain the existing read while releasing its own action correlation");
    const auto read = transport.recorded.last<ReadPane>();

    deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Recent rows", .exit_code = {}});
    check(!client.requestsPending(), "the surviving read must release its own correlation when its reply arrives");
    transport.reject = false;
    check(application::peek::submit(client, "/stop") && transport.recorded.count(ClientTag::interrupt_agent) == 1, "retrying a rejected action admits exactly one interrupt");
  }

  void peekRowsUseSaturatingOriginalCellCoordinates() {
    constexpr CellRectangle host{.x = std::numeric_limits<std::uint16_t>::max(), .y = std::numeric_limits<std::uint16_t>::max(), .width = 100, .height = 30};
    const auto geometry = PeekGeometry::measure(host);

    check(geometry.bounds.x == host.x && geometry.bounds.y == host.y && geometry.field.y == host.y && geometry.footer.y == host.y, "peek modal and row offsets must saturate instead of wrapping near the cell coordinate limit");
    check(geometry.screen.height == geometry.bounds.height - PeekGeometry::chrome_rows - 2, "peek screen rows must reserve border and original chrome rows");
    constexpr CellRectangle narrow{.width = 3, .height = 3};
    const auto tiny = PeekGeometry::measure(narrow);

    check(tiny.facts.empty() && tiny.field.empty(), "a modal with less than four inner rows must keep only its border and title");
  }

  void snapshotsRefreshMetadataWithoutAttachingThePeekedPane() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    const auto openings = transport.count(ClientTag::open_pane);

    check(application::peek::open(client, target), "a live agent may be inspected without selecting its tab");
    const auto read = transport.last<ReadPane>();

    deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
    check(transport.count(ClientTag::read_pane) == 1, "snapshots coalesce while the same peek read is in flight");
    check(deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Owned recent text", .exit_code = {}}) == application::Change::peek && application::peek::text(client) == "Owned recent text", "a recent pane reply updates only peek presentation");
    check(client.focusedPane()->id == 1 && client.findPane(target.agent.pane_id) == nullptr && transport.count(ClientTag::open_pane) == openings, "a peek must retain the current tab and create no terminal screen or attachment");
    auto wrong = target;

    ++wrong.session.front();
    check(!application::peek::open(client, wrong) && application::peek::text(client) == "Owned recent text", "an invalid replacement cannot erase a live peek");
    deliver(client, AgentSnapshot{.revision = 3, .entries = agents});
    const auto refresh = transport.last<ReadPane>();

    check(refresh.request_id != read.request_id, "a later accepted snapshot asks for fresh recent rows");
    ++agents.front().session_id.front();
    deliver(client, AgentSnapshot{.revision = 4, .entries = agents});
    check(!application::peek::target(client) && !application::peek::submit(client, "/stop"), "reused pane and generation values cannot retain a retired agent session");
    check(deliver(client, PaneText{.request_id = refresh.request_id, .pane_id = read.pane_id, .text = "Retired data", .exit_code = {}}) == application::Change::none && application::peek::text(client).empty(), "a retired session's delayed pane text must stay invisible");
  }

  void peekMessagesAndInterruptsKeepTheOriginalProtocol() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target) && application::peek::submit(client, " \tPlease continue \t"), "a peek may submit its field directly to the owned agent");
    const auto message = transport.last<SendPaneText>();

    check(message.pane_id == target.agent.pane_id && message.pane_generation == target.agent.pane_generation && message.mode == PaneTextMode::prompt && message.text == "Please continue" && !message.sender, "peek messages preserve prompt delivery and trim only the field edges");
    check(transport.count(ClientTag::pane_input) == 0 && !application::peek::target(client), "peek prompt submission must not type into the focused local pane");
    const auto read = transport.last<ReadPane>();

    check(deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Closed read", .exit_code = {}}) == application::Change::none, "closing the field must retain and safely retire a later read reply");
    deliver(client, RequestCompleted{.request_id = message.request_id});
    check(!client.requestsPending() && application::peek::open(client, target) && application::peek::submit(client, "/stop"), "an interrupt has its own releasable action correlation");
    const auto interrupt = transport.last<InterruptAgent>();

    check(interrupt.pane_id == target.agent.pane_id && interrupt.pane_generation == target.agent.pane_generation, "peek stop must address the original agent generation");
    const auto stopped_read = transport.last<ReadPane>();

    check(deliver(client, RequestFailed{.request_id = stopped_read.request_id, .code = FailureCode::pane_not_found, .message = "Read retired"}) == application::Change::none && client.error().empty(), "a read rejected after its peek closes must release quietly");
    deliver(client, RequestCompleted{.request_id = interrupt.request_id});
    check(application::peek::open(client, target), "a completed action leaves later peeks available");
    client.setPresented(false);
    check(!application::peek::target(client) && !application::peek::submit(client, "Ignored") && !application::peek::open(client, target), "a hidden machine must discard peek interaction ownership");
  }

  void diffLaunchQuotesItsBranchAsAnArgumentAndWaitsForHandoff() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};
    const std::array worktrees{WorktreeListEntry{.worktree = worktree_id, .source = 1, .workspace = location.workspace.id, .path = "/project/checkout", .branch = "feature;touch injected"}};

    deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target), "a task-backed agent may be inspected");
    const auto read = transport.last<ReadPane>();

    deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Task rows", .exit_code = {}});
    check(application::peek::submit(client, "/diff"), "a task-backed peek may launch its diff command");
    const auto launch = transport.last<LaunchWorktree>();
    constexpr TerminalSize original_size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};

    check(launch.worktree == worktree_id && launch.label == "diff" && launch.size.cols == original_size.cols && launch.size.rows == original_size.rows && launch.size.cell_width_px == original_size.cell_width_px && launch.size.cell_height_px == original_size.cell_height_px && launch.launch.cwd == worktrees.front().path, "peek diffs preserve task ownership and the original terminal size");
    constexpr std::size_t diff_argument_count = 5;
    constexpr std::size_t script_index = 2;

    check(launch.launch.arguments.size() == diff_argument_count && launch.launch.arguments.back() == worktrees.front().branch && !launch.launch.arguments[script_index].contains(worktrees.front().branch), "a branch must travel as one argument rather than shell script text");
    constexpr std::uint64_t diff_pane = 77;

    deliver(client, PaneOpened{.request_id = launch.request_id, .pane_id = diff_pane, .location = location, .created = true, .pane_generation = 1});
    const auto open = transport.last<OpenPane>();

    check(open.target.kind == PaneTarget::Kind::pane && open.target.id == diff_pane && client.findPane(diff_pane) == nullptr, "a launched diff must await the normal canonical pane handoff instead of constructing an incomplete screen");
  }

  void openingTaskPeekDetachesBeforeItsCanonicalPaneHandoff() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target), "a task agent must admit its read");
    const auto read = transport.last<ReadPane>();

    deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Task", .exit_code = {}});
    const auto first = transport.sent.size();

    check(application::peek::submit(client, "/open"), "the task peek must close after handing off its source");
    check(transport.count(ClientTag::detach_pane) == 1 && transport.detaching == std::vector<std::uint64_t>{1}, "the current workspace must release its input and attachment before entering another");
    const auto messages = std::span{transport.sent}.subspan(first);
    const auto detach = std::ranges::find_if(messages, [](const auto& bytes) {
      return bytes.front() == static_cast<Byte>(ClientTag::detach_pane);
    });

    const auto opening = std::ranges::find_if(messages, [](const auto& bytes) {
      return bytes.front() == static_cast<Byte>(ClientTag::open_pane);
    });

    check(detach < opening && opening != messages.end(), "the runtime must see the departure before the target attachment");
    check(client.activeTab() == nullptr && client.panes().empty(), "screens must retire after the complete handoff is queued, awaiting a canonical root");
    const auto request = transport.last<OpenPane>();

    check(request.target.kind == PaneTarget::Kind::pane && request.target.id == target.agent.pane_id && !request.launch, "a task visit must reopen an existing pane without a new process");
    deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = target.agent.pane_id, .location = location, .pane_generation = target.agent.pane_generation});
    check(client.focusedPane() != nullptr && client.focusedPane()->id == target.agent.pane_id && client.focusedPane()->attached && sameTab(client.activeTab()->location, location), "the canonical reply must activate only the requested task pane and workspace");
  }

  void aBusyTaskPeekOpenClosesWithoutLeavingItsCurrentWorkspace() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target), "a task peek read must remain tracked");
    const auto read = transport.last<ReadPane>();
    const auto openings = transport.count(ClientTag::open_pane);

    check(application::peek::submit(client, "/open") && !application::peek::target(client), "a busy open still closes its peek as the original does");
    check(transport.count(ClientTag::open_pane) == openings && transport.count(ClientTag::detach_pane) == 0 && client.focusedPane()->id == 1 && client.focusedPane()->attached, "an outstanding canonical reply must fence workspace departure");
    deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Late read", .exit_code = {}});
    check(!client.requestsPending(), "the closed peek's late reply must release its original correlation");
  }

  void aMissingTaskPaneRetriesItsWorkspaceOnlyOnce() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::activity::chooseAgent(client, target.agent.pane_id, target.agent.pane_generation), "the known agent must admit navigation");
    const auto request = transport.last<OpenPane>();

    deliver(client, RequestFailed{.request_id = request.request_id, .code = FailureCode::pane_not_found, .message = "Task pane gone"});
    const auto fallback = transport.last<OpenPane>();

    check(fallback.request_id != request.request_id && fallback.target.kind == PaneTarget::Kind::workspace && fallback.target.id == location.workspace.id && !fallback.launch, "a disappeared agent pane must fall back once to its authoritative workspace");
    const auto openings = transport.count(ClientTag::open_pane);

    deliver(client, RequestFailed{.request_id = fallback.request_id, .code = FailureCode::workspace_not_found, .message = "Task workspace gone"});
    check(transport.count(ClientTag::open_pane) == openings && !client.requestsPending(), "a failed workspace fallback must not start an unbounded open loop");
  }

  void aRejectedTaskOpenRestoresItsDepartingAttachment() {
    SystemAllocator memory;
    PeekTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport.recorded);
    const auto source = client.activeTab()->location;
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    transport.reject_open = true;
    bool rejected = false;

    try {
      static_cast<void>(application::activity::chooseAgent(client, target.agent.pane_id, target.agent.pane_generation));
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && client.activeTab() != nullptr && sameTab(client.activeTab()->location, source) && client.findPane(1) != nullptr && client.findPane(target.agent.pane_id) == nullptr, "rejected target delivery must retain the old projection and its owned screens");
    check(transport.recorded.count(ClientTag::detach_pane) == 1, "the fixture must exercise rejection after an accepted departure");
    const auto repair = transport.recorded.last<OpenPane>();

    check(repair.target.kind == PaneTarget::Kind::pane && repair.target.id == 1 && client.findPane(1)->attaching, "accepted detaches must be repaired through a fresh correlated attachment");
    deliver(client, PaneOpened{.request_id = repair.request_id, .pane_id = 1, .location = source, .pane_generation = 1});
    check(client.focusedPane()->id == 1 && client.focusedPane()->attached && !client.requestsPending(), "the source's canonical repair must restore its original usable pane");
  }

  void aPartialTaskDepartureRepairsOnlyItsAcceptedDetaches() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

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
      static_cast<void>(application::activity::chooseAgent(client, target.agent.pane_id, target.agent.pane_generation));
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && client.panes().size() == panes.size() && sameTab(client.activeTab()->location, source), "partial departure must retain the complete previous projection");
    check(transport.count(ClientTag::detach_pane) == 1 && client.findPane(2)->attached, "an unaccepted detach must leave its original attachment committed");
    const auto repair = transport.last<OpenPane>();

    check(repair.target.id == 1 && client.findPane(1)->attaching, "only the successfully detached pane must request repair");
    deliver(client, PaneOpened{.request_id = repair.request_id, .pane_id = 1, .location = source, .pane_generation = 1});
    check(client.findPane(1)->attached && client.findPane(2)->attached && !client.requestsPending(), "canonical repair must leave both previous panes usable");
  }

  void aDiffArrivalWithPendingPeekReadKeepsItsCurrentWorkspace() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};
    const std::array worktrees{WorktreeListEntry{.worktree = worktree_id, .source = 1, .workspace = location.workspace.id, .path = "/project/checkout", .branch = "worktree/task"}};

    deliver(client, WorkspaceList{.revision = 1, .worktrees = worktrees});
    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target), "the busy diff fixture must keep its real peek read pending");
    const auto read = transport.last<ReadPane>();

    check(application::peek::submit(client, "/diff"), "a diff may launch before its retained read finishes");
    const auto launch = transport.last<LaunchWorktree>();
    const auto openings = transport.count(ClientTag::open_pane);
    constexpr std::uint64_t diff_pane = 77;

    deliver(client, PaneOpened{.request_id = launch.request_id, .pane_id = diff_pane, .location = location, .pane_generation = 1});
    check(transport.count(ClientTag::open_pane) == openings && transport.count(ClientTag::detach_pane) == 0 && client.focusedPane()->id == 1 && client.focusedPane()->attached, "a pending canonical read must fence automatic navigation to a launched diff");
    deliver(client, PaneText{.request_id = read.request_id, .pane_id = read.pane_id, .text = "Closed read", .exit_code = {}});
    check(!client.requestsPending() && transport.count(ClientTag::open_pane) == openings && client.findPane(diff_pane) == nullptr, "a retired read must not start a delayed handoff that the original ignored");
  }

  void peekReadFailuresRetryAndRejectedActionsNotifyTheirPane() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const std::array agents{agent()};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    check(application::peek::open(client, target), "a live peek must admit its initial read");
    const auto read = transport.last<ReadPane>();

    check(deliver(client, RequestFailed{.request_id = read.request_id, .code = FailureCode::pane_not_found, .message = "Read rejected"}) == application::Change::none && !application::peek::reading(client) && application::peek::target(client), "a failed recent read must quietly release ownership while keeping the open peek");
    check(client.error().empty() && application::notifications::center(client).items().empty() && !client.requestsPending(), "a recent-read failure must not turn into an unrelated diagnostic or notification");
    deliver(client, AgentSnapshot{.revision = 2, .entries = agents});
    const auto retry = transport.last<ReadPane>();

    check(retry.request_id != read.request_id, "the next accepted agent snapshot retries a failed read");
    deliver(client, PaneText{.request_id = retry.request_id, .pane_id = retry.pane_id, .text = "Recent reply", .exit_code = {}});
    check(application::peek::submit(client, "Please continue"), "a peek may hand off its field and close before the action reply");
    const auto action = transport.last<SendPaneText>();
    constexpr std::string_view refusal = "the pane has the focus in an attached window";

    check(deliver(client, RequestFailed{.request_id = action.request_id, .code = FailureCode::pane_focused, .message = refusal}) == application::Change::notification, "a refused peek action must publish the original failure notification");
    check(application::notifications::center(client).items().size() == 1 && !client.requestsPending(), "a refusal must retain one notice and release the action correlation");
    const auto& notice = application::notifications::center(client).items().front();
    constexpr std::uint64_t original_duration_ns = 7'000'000'000;

    check(notice.level == NotificationLevel::failure && notice.title.view() == "The agent did not take it" && notice.message.view() == refusal && notice.target.kind == NotificationTarget::Kind::pane && notice.target.id == target.agent.pane_id, "the failure card must retain the original text and inspected pane target");
    check(notice.expires_at_ns - notice.transition_updated_ns == original_duration_ns + NotificationItem::transition_duration_ns, "peek action failures retain their original seven-second lifetime");
  }

  const telar::testing::Case case_commands_and_visible_tail_preserve_original_text{"agent_peek.commands_and_visible_tail_preserve_original_text", commandsAndVisibleTailPreserveOriginalText};
  const telar::testing::Case case_peek_rows_use_saturating_original_cell_coordinates{"agent_peek.peek_rows_use_saturating_original_cell_coordinates", peekRowsUseSaturatingOriginalCellCoordinates};
  const telar::testing::Case case_retained_screen_owns_its_read_and_uses_bounded_injected_memory{"agent_peek.retained_screen_owns_its_read_and_uses_bounded_injected_memory", retainedScreenOwnsItsReadAndUsesBoundedInjectedMemory};
  const telar::testing::Case case_rejected_transport_releases_only_its_own_admission{"agent_peek.rejected_transport_releases_only_its_own_admission", rejectedTransportReleasesOnlyItsOwnAdmission};
  const telar::testing::Case case_snapshots_refresh_metadata_without_attaching_the_peeked_pane{"agent_peek.snapshots_refresh_metadata_without_attaching_the_peeked_pane", snapshotsRefreshMetadataWithoutAttachingThePeekedPane};
  const telar::testing::Case case_peek_messages_and_interrupts_keep_the_original_protocol{"agent_peek.peek_messages_and_interrupts_keep_the_original_protocol", peekMessagesAndInterruptsKeepTheOriginalProtocol};
  const telar::testing::Case case_diff_launch_quotes_its_branch_as_an_argument_and_waits_for_handoff{"agent_peek.diff_launch_quotes_its_branch_as_an_argument_and_waits_for_handoff", diffLaunchQuotesItsBranchAsAnArgumentAndWaitsForHandoff};
  const telar::testing::Case case_opening_task_peek_detaches_before_its_canonical_pane_handoff{"agent_peek.opening_task_peek_detaches_before_its_canonical_pane_handoff", openingTaskPeekDetachesBeforeItsCanonicalPaneHandoff};
  const telar::testing::Case case_a_busy_task_peek_open_closes_without_leaving_its_current_workspace{"agent_peek.a_busy_task_peek_open_closes_without_leaving_its_current_workspace", aBusyTaskPeekOpenClosesWithoutLeavingItsCurrentWorkspace};
  const telar::testing::Case case_a_missing_task_pane_retries_its_workspace_only_once{"agent_peek.a_missing_task_pane_retries_its_workspace_only_once", aMissingTaskPaneRetriesItsWorkspaceOnlyOnce};
  const telar::testing::Case case_a_rejected_task_open_restores_its_departing_attachment{"agent_peek.a_rejected_task_open_restores_its_departing_attachment", aRejectedTaskOpenRestoresItsDepartingAttachment};
  const telar::testing::Case case_a_partial_task_departure_repairs_only_its_accepted_detaches{"agent_peek.a_partial_task_departure_repairs_only_its_accepted_detaches", aPartialTaskDepartureRepairsOnlyItsAcceptedDetaches};
  const telar::testing::Case case_a_diff_arrival_with_pending_peek_read_keeps_its_current_workspace{"agent_peek.a_diff_arrival_with_pending_peek_read_keeps_its_current_workspace", aDiffArrivalWithPendingPeekReadKeepsItsCurrentWorkspace};
  const telar::testing::Case case_peek_read_failures_retry_and_rejected_actions_notify_their_pane{"agent_peek.peek_read_failures_retry_and_rejected_actions_notify_their_pane", peekReadFailuresRetryAndRejectedActionsNotifyTheirPane};

}
