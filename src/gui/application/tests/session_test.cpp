#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.features.workbench;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.runtime;
import telar.gui.foundation.model;
import telar.base.ds;
import telar.client;
import telar.wire.vocabulary;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.base.memory.allocators;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::workbench;
  using namespace telar::gui::application::tests::session_fixture;

  void sessionLifecycle() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{16} * 1024 * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Transport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      check(client.focusedPane() != nullptr && client.focusedPane()->id == 1, "opened pane must receive focus");

      constexpr std::string_view input_text = "hello";

      client.input(1, input_text);
      const auto input = transport.last<PaneInput>();

      check(input.bytes.size() == input_text.size() && input.bytes[0] == 'h', "input must preserve bytes");

      application::workbench::split(client, ClientLayoutAxis::vertical);
      const auto split = transport.last<CreatePane>();

      check(split.launch.cwd_source == 1, "split must inherit source pane cwd");
      deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
      check(client.activeTab()->layout.nodes().size() == 3, "split must retain a binary layout");
      check(std::get<ClientLayoutSplit>(client.activeTab()->layout.nodes().front()).axis == ClientLayoutAxis::vertical, "split axis must survive the response");

      application::workbench::closePane(client, 2);
      deliver(client, PaneExited{.pane_id = 2, .kind = ExitKind::exited, .value = 0});
      check(client.activeTab()->layout.nodes().size() == 1 && client.focusedPane()->id == 1, "closing a pane must collapse its split and restore focus");
      check(client.findPane(2) == nullptr, "exited panes must release retained screens and graphics");

      application::workbench::createTab(client);
      const auto created = transport.last<CreateTab>();
      const TabLocation second{.workspace = created.workspace, .tab_id = 2};

      deliver(client, TabCreated{.request_id = created.request_id, .location = second, .position = 1, .label = "Second", .root_pane_id = 3, .pane_generation = 1});
      check(client.focusedPane()->id == 3 && !client.findPane(1)->attached, "switching tabs must detach hidden panes");
      check(!transport.detaching.empty() && transport.detaching.back() == 1, "input owners must release physical keys before a pane detaches");

      application::workbench::selectTab(client, {.workspace = created.workspace, .tab_id = 1});
      const auto attach = transport.last<OpenPane>();

      check(attach.target.kind == PaneTarget::Kind::pane && attach.target.id == 1 && !attach.launch, "reattachment must not spawn a process");
      deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 1, .location = {.workspace = created.workspace, .tab_id = 1}, .created = false, .pane_generation = 1});

      application::workbench::selectTabBeside(client, -1);
      check(client.activeTab()->location.tab_id == 2, "previous-tab must wrap in runtime tab order");
      const auto second_attach = transport.last<OpenPane>();

      deliver(client, PaneOpened{.request_id = second_attach.request_id, .pane_id = 3, .location = second, .created = false, .pane_generation = 1});
      application::workbench::selectTabBeside(client, 1);
      check(client.activeTab()->location.tab_id == 1, "next-tab must wrap in runtime tab order");
      application::workbench::selectTabAt(client, 0);
      check(client.activeTab()->location.tab_id == 1, "indexed tab selection must use runtime tab positions");

      client.disconnected();
      check(!client.ready() && !client.findPane(1)->attached, "disconnect must invalidate attachment state");
      client.connected(1);
      check(client.activeTab() == nullptr && client.panes.empty(), "a new runtime session must discard the former projection before receiving its bootstrap snapshot");
      const TabLocation restored_location{.workspace = created.workspace, .tab_id = 1};
      const ds::Array<ClientLayoutNode, 1> restored_nodes{ClientLayoutPane{1}};
      const ds::Array restored_tabs{ClientTabLayout{.location = restored_location, .focused_pane = 1, .workspace_active = true, .nodes = restored_nodes}};

      deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_width = decltype(client)::default_sidebar_columns, .active_tab = restored_location, .tabs = restored_tabs});
      check(transport.last<OpenPane>().target.id == 1 && !transport.last<OpenPane>().launch, "reconnect must restore the current pane from the runtime's owned layout snapshot");
    }

    check(budget.liveBytes() == 0, "session must release injected allocations");
  }

  void detachedTabForegroundsAndAgentTitles() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Transport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      const auto location = client.activeTab()->location;
      constexpr std::uint64_t unfocused_active_pane = 7;
      constexpr std::uint64_t remembered_detached_pane = 12;
      constexpr std::uint64_t other_detached_pane = 13;
      const ds::Array active_names{TabPane{.pane_id = unfocused_active_pane, .foreground = "other"}, TabPane{.pane_id = 1, .foreground = "Python"}};
      const ds::Array detached_names{TabPane{.pane_id = remembered_detached_pane, .foreground = "nvim", .cwd = "/projects/detached"}, TabPane{.pane_id = other_detached_pane, .foreground = "git", .cwd = "/projects/other"}};
      const ds::Array tabs{
          TabDescriptor{.tab_id = location.tab_id, .position = 0, .pane_count = 2, .panes = active_names},
          TabDescriptor{.tab_id = 2, .position = 1, .pane_count = 2, .panes = detached_names},
      };

      deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = location.workspace, .name = "project", .tabs = tabs});
      const auto* const entry = std::ranges::find_if(client.tabs, [](const auto& tab) {
        return tab->location.tab_id == 2;
      });

      check(entry != client.tabs.end() && client.findPane(remembered_detached_pane) == nullptr, "workspace metadata must not instantiate detached panes");
      const auto* detached = &entry->get();

      check(application::tabApplicationName(*client.activeTab(), client.focusedPane()) == "Python", "foreground snapshots must honor this client's focused pane");
      check(application::tabApplicationName(*detached, nullptr) == "nvim", "detached tabs must retain the first reported application until focus is known");
      deliver(client, PaneForeground{.pane_id = remembered_detached_pane, .name = "vim"});
      deliver(client, PaneForeground{.pane_id = other_detached_pane, .name = "lazygit"});
      check(application::tabApplicationName(*detached, nullptr) == "vim", "detached reports must update only the remembered foreground pane");
      check(std::string_view{detached->directory} == "/projects/detached", "detached tabs must show the listed directory of their foreground pane");
      check(detached->members.size() == 2 && detached->members[0].foreground.view() == "vim" && detached->members[1].foreground.view() == "lazygit", "detached tabs must list every pane and follow its foreground reports");
      const ds::Array agents{AgentSnapshotEntry{.pane_id = 1, .pane_generation = 1, .location = location, .pane_index = 1, .workspace_label = "Copied workspace metadata", .session_title = "Working session", .title_source = AgentTitleSource::agent, .title_state = AgentTitleState::ready, .provider = AgentProvider::codex, .provider_name = "codex", .display_name = "Custom display name", .icon = "?", .status = AgentStatus::blocked, .blocked_reason = AgentBlockedReason::permission, .sequence = 1}};

      deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
      check(client.agents().size() == 1 && client.agents().front().title_state == AgentTitleState::ready && client.agents().front().title == "Working session", "agent snapshots must preserve title eligibility as well as its text");
      const auto& agent = client.agents().front();

      check(agent.workspace_label == "Copied workspace metadata" && agent.display_name == "Custom display name" && agent.icon == "?", "agent cards must retain their copied context and display metadata");
      check(agent.provider_name == "codex", "the manifest name must remain separate from the human display name");
      check(agent.provider_kind == AgentProvider::codex && agent.blocked_reason == AgentBlockedReason::permission, "agent cards must retain typed provider and blocked reason");
    }

    check(budget.liveBytes() == 0, "foreground and agent-title metadata must release injected allocations");
  }

  void configuredWindowTitles() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    Transport transport;

    {
      TestSession client{memory, transport};

      check(application::window::title(client, "host").view() == "Telar", "the GUI default title must match the original even without a pane");
      openFirstPane(client, transport);
      const auto location = client.activeTab()->location;
      const ds::Array entries{WorkspaceListEntry{.workspace = location.workspace.id, .name = "project", .path = "/project"}};

      deliver(client, WorkspaceList{.revision = 1, .entries = entries});
      Configuration configuration;

      configuration.window_title.assign("{workspace}/{tab}/{pane_title}@{hostname}");
      application::configuration::configure(client, configuration);
      check(application::window::title(client, "host").view() == "project/shell/@host", "automatic tab labels must default to shell before foreground discovery");

      const ds::Array metadata_panes{TabPane{.pane_id = 1, .foreground = "Python"}};
      const ds::Array metadata_tabs{TabDescriptor{.tab_id = location.tab_id, .position = 0, .pane_count = 1, .panes = metadata_panes}};

      deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = location.workspace, .name = "project", .tabs = metadata_tabs});
      check(application::window::title(client, "host").view() == "project/Python/@host", "configured titles must use remembered foreground metadata before a pane report arrives");

      deliver(client, PaneTitle{.pane_id = 1, .title = "compiler"});
      deliver(client, PaneForeground{.pane_id = 1, .name = "nvim"});
      const auto allocations = budget.allocations();
      const auto rendered = application::window::title(client, "host");

      check(rendered.view() == "project/nvim/compiler@host", "titles must follow current workspace, foreground and pane metadata");
      check(budget.allocations() == allocations, "title projection must not allocate through the session allocator");
      const ds::Array tabs{TabDescriptor{.tab_id = location.tab_id, .label = "manual"}};

      deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = location.workspace, .name = "renamed", .tabs = tabs});
      check(application::window::title(client, "host").view() == "renamed/manual/compiler@host", "manual tab labels and renamed workspaces must replace automatic title tokens");
      application::workbench::split(client, ClientLayoutAxis::horizontal);
      const auto request = transport.last<CreatePane>();

      deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = 2, .location = location, .created = true, .pane_generation = 1});
      deliver(client, PaneTitle{.pane_id = 2, .title = "second"});
      check(application::window::title(client, "host").view() == "renamed/manual/second@host", "focused pane changes must select that pane's title");
      check(rendered.view() == "project/nvim/compiler@host", "an earlier rendered value must not borrow mutable session strings");
      application::configuration::configure(client, Configuration{});
      check(application::window::title(client, "host").view() == "Telar", "clearing a configured template must restore the original GUI default");
    }

    check(budget.liveBytes() == 0, "title projection must preserve session allocation ownership");
  }

  void restoredLayoutAndFailure() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    constexpr std::uint64_t client_identity = 9;
    constexpr std::uint64_t pane_id = 11;
    constexpr std::uint16_t sidebar_columns = 32;

    client.connected(client_identity);
    const TabLocation location{.workspace = WorkspaceLocation{.kind = WorkspaceLocation::Kind::workspace, .id = 4}, .tab_id = 7};
    const ds::Array<ClientLayoutNode, 1> nodes{ClientLayoutPane{pane_id}};
    const ds::Array<ClientTabLayout, 1> tabs{{{.location = location, .focused_pane = pane_id, .fullscreen = false, .workspace_active = true, .nodes = nodes}}};

    deliver(client, ClientLayoutSnapshot{.restored = true, .sidebar_visible = false, .sidebar_width = sidebar_columns, .workspace_list_collapsed = true, .active_tab = location, .tabs = tabs});
    check(!client.configuration.sidebar_visible && client.activeTab() == nullptr, "saved sidebar preferences must restore before the canonical root is received");
    check(client.workspaceListCollapsed(), "saved workspace collapse preference must restore");
    const auto opening = transport.last<OpenPane>();

    check(transport.count(ClientTag::open_pane) == 1 && opening.target.id == pane_id && !opening.launch, "startup must reopen its remembered pane before requesting canonical membership");
    deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = pane_id, .location = location, .pane_generation = 3});
    check(client.activeTab()->focused_pane == pane_id, "the authoritative restored root must receive focus");

    constexpr std::uint64_t other_pane = pane_id + 1;
    const ds::Array panes{PaneDescriptor{.pane_id = pane_id, .lifecycle = PaneLifecycle::running, .pane_generation = 3}, PaneDescriptor{.pane_id = other_pane, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};

    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
    const auto attach = transport.last<OpenPane>();

    check(attach.target.id == other_pane, "canonical membership must request the second pane through the normal attachment lifecycle");
    deliver(client, RequestFailed{.request_id = attach.request_id, .code = FailureCode::pane_not_found, .message = "Pane disappeared"});
    check(!client.findPane(other_pane)->attaching && client.error() == "Pane disappeared", "failed attachment must release its pending lease");
  }

  void pendingAttachmentKeepsTheLatestViewport() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto original = client.activeTab()->location;

    application::workbench::createTab(client);
    const auto create = transport.last<CreateTab>();
    const TabLocation second{.workspace = create.workspace, .tab_id = 2};

    deliver(client, TabCreated{.request_id = create.request_id, .location = second, .position = 1, .root_pane_id = 2, .pane_generation = 1});
    application::workbench::selectTab(client, original);
    const auto attach = transport.last<OpenPane>();
    const auto before = transport.count(ClientTag::pane_resize);
    auto latest = attach.size;

    ++latest.cols;
    ++latest.rows;
    client.resize(1, latest);
    check(transport.count(ClientTag::pane_resize) == before, "a pending attachment must retain its desired size without sending to a detached pane");
    deliver(client, PaneOpened{.request_id = attach.request_id, .pane_id = 1, .location = original, .pane_generation = 1});
    check(transport.count(ClientTag::pane_resize) == before + 1, "an attachment confirmation must deliver the viewport changed while its request was pending");
    const auto resized = transport.last<PaneResize>().size;

    check(resized.cols == latest.cols && resized.rows == latest.rows, "the confirmed attachment must receive the latest desired dimensions");

    auto rejected_size = latest;

    ++rejected_size.cols;
    const auto version = client.viewVersion();

    transport.reject_next_pane_resize = true;
    bool rejected = false;

    try {
      client.resize(1, rejected_size);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && client.findPane(1)->size.cols == latest.cols && client.viewVersion() == version, "a rejected resize must preserve the last admitted size and viewport revision");
    client.resize(1, rejected_size);
    check(transport.last<PaneResize>().size.cols == rejected_size.cols, "a rejected resize must remain retryable");
  }

  void staleHistory() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::history::search(client, "old");
    const auto old_request = transport.last<QueryHistory>().request_id;

    application::history::search(client, "new");
    const auto new_request = transport.last<QueryHistory>().request_id;
    const ds::Array<HistoryEntry, 1> rows{{{.id = 1, .pane_id = 1, .command = "echo result", .cwd = "/tmp"}}};

    check(deliver(client, HistoryResults{.request_id = old_request, .snapshot_id = 1, .has_more = false, .entries = rows}) == application::Change::none, "stale search results must not replace the current query");
    deliver(client, HistoryResults{.request_id = new_request, .snapshot_id = 1, .has_more = false, .entries = rows});
    check(application::history::view(client).rows().size() == 1 && application::history::view(client).rows().front().command == "echo result", "history results must own command bytes");
  }

  void routedCommands() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ClientCommand command;

    command.request_id = 1;
    command.route = {.id = 1, .generation = 1};
    command.action = ClientAction::sidebar_hide;
    check(deliver(client, command) == application::Change::sidebar && !client.configuration.sidebar_visible, "routed sidebar commands must update window state");
    constexpr std::uint16_t expected_sidebar_columns = 42;
    const auto hidden = transport.last<CompleteClientCommand>();

    check(hidden.status == ClientCommandStatus::applied && hidden.text == "hidden" && std::cmp_equal(hidden.value, expected_sidebar_columns), "routed command replies must preserve the sidebar wire contract");

    command.request_id = 2;
    command.action = ClientAction::pane_split;
    command.target_id = 1;
    command.text = "vertical";
    deliver(client, command);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    application::workbench::focusPane(client, 1);
    deliver(client, PaneFocusCommand{.requester = {.id = 1, .generation = 1}, .request_id = 3, .pane_id = 1, .pane_generation = 1, .direction = PaneDirection::down});
    check(client.focusedPane()->id == 2 && transport.last<CompletePaneFocus>().outcome == PaneFocusOutcome::focused, "directional focus must choose the neighboring split");

    command.request_id = 4;
    command.action = ClientAction::pane_resize;
    command.target_id = 2;
    command.text = "up";
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::applied && std::get<ClientLayoutSplit>(client.activeTab()->layout.nodes().front()).ratio == PaneLayout::ratio_half - PaneLayout::resize_step, "routed resizing must update the persisted layout");

    ++command.request_id;
    command.action = ClientAction::plugin_run;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "unsupported routed commands must complete instead of hanging the caller");

    constexpr std::uint16_t display_refresh_rate = 144;
    constexpr std::uint16_t configured_frame_cap = 120;
    constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;

    application::window::setRefreshRate(client, display_refresh_rate);
    auto configuration = client.configuration;

    configuration.max_fps = configured_frame_cap;
    application::configuration::configure(client, configuration);
    application::window::pace(client);
    check(transport.last<ConfigureFrameInterval>().interval_ns == nanoseconds_per_second / configured_frame_cap, "terminal cadence must follow the configured display cap");

    configuration.max_fps = 1;
    application::configuration::configure(client, configuration);
    application::window::pace(client);
    check(transport.last<ConfigureFrameInterval>().interval_ns == nanoseconds_per_second / Configuration::minimum_fps, "terminal cadence must remain inside protocol bounds for a low frame cap");
  }

  void routedSidebarResize() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    constexpr std::uint16_t host_columns = 120;
    constexpr std::uint16_t preferred_columns = 70;

    client.setHostColumns(host_columns);
    client.setSidebarVisible(false);
    const auto logical_width = client.configuration.sidebar_width;
    ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::sidebar_resize, .value = preferred_columns};

    check(deliver(client, command) == application::Change::sidebar, "an exact sidebar column request must update semantic layout state");
    const auto resized = transport.last<CompleteClientCommand>();

    check(resized.status == ClientCommandStatus::applied && resized.value == command.value && resized.text == "hidden", "a resize must report the clamped width without changing visibility");
    check(std::cmp_equal(transport.last<UpdateClientLayout>().sidebar_width, command.value), "a changed semantic sidebar width must reach runtime-retained layout state");
    const auto layouts = transport.count(ClientTag::update_client_layout);

    check(deliver(client, command) == application::Change::none && transport.count(ClientTag::update_client_layout) == layouts, "repeating a sidebar width must preserve layout ownership without another retention request");
    constexpr auto maximum_columns = std::numeric_limits<std::uint16_t>::max();

    command.value = maximum_columns;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().value == host_columns - application::SidebarColumns::minimum_workbench, "an exact width must preserve twenty workbench columns");
    client.setHostColumns(application::SidebarColumns::minimum_workbench);
    command.value = 1;
    deliver(client, command);
    check(std::cmp_equal(transport.last<CompleteClientCommand>().value, application::SidebarColumns::minimum_width), "a temporarily narrow host must retain the semantic minimum width");
    for (const auto invalid : {std::int64_t{-1}, std::int64_t{0}, std::int64_t{maximum_columns} + 1, std::numeric_limits<std::int64_t>::max()}) {
      command.value = invalid;
      const auto before = transport.count(ClientTag::update_client_layout);

      deliver(client, command);
      const auto rejected = transport.last<CompleteClientCommand>();

      check(rejected.status == ClientCommandStatus::failed && rejected.text == "InvalidWidth", "invalid exact widths must fail with the original command error");
      check(transport.count(ClientTag::update_client_layout) == before, "a rejected width must preserve the previous retained state");
    }

    check(client.configuration.sidebar_width == logical_width, "semantic CLI columns must remain independent of the GUI's logical pixel preference");
  }

  void routedCopyRange() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::vertical);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});

    ClientCommand command;

    command.request_id = 1;
    command.route = {.id = 1, .generation = 1};
    command.action = ClientAction::pane_copy;
    command.target_id = 1;
    command.text = "0,10:79,12";
    deliver(client, command);
    const auto copied = transport.last<CopySelection>();
    constexpr std::uint32_t start_row = 10;
    constexpr std::uint16_t end_column = 79;
    constexpr std::uint32_t end_row = 12;

    check(copied.pane_id == 1 && copied.start_x == 0 && copied.start_y == start_row && copied.end_x == end_column && copied.end_y == end_row, "routed copy must use full history coordinates");
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::admitted, "routed copy must acknowledge its asynchronous runtime request");
    check(client.focusedPane()->id == 2, "copying another pane must preserve the focused pane");

    const auto requests = transport.count(ClientTag::copy_selection);

    command.request_id = 2;
    command.text = "65536,0:0,0";
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed && transport.count(ClientTag::copy_selection) == requests, "invalid coordinates must not reach the runtime");

    command.request_id = 3;
    command.target_id = 0;
    command.text = "0,0:0,0";
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed && transport.count(ClientTag::copy_selection) == requests, "copying an unknown pane must fail without a runtime request");

    const ds::Array<Byte, 4> clipboard{'c', 'o', 'p', 'y'};

    check(deliver(client, PaneClipboard{.pane_id = 1, .bytes = clipboard}) == application::Change::clipboard && client.clipboard() == "copy", "asynchronous runtime clipboard data must be exposed to the platform");
  }

  void pointerSelectionLifecycle() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    constexpr std::uint32_t history_rows = 3;

    deliverSingleCell(client, {.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = history_rows}});
    check(application::terminal::copy_mode::press(client, {.pane_id = 1}), "an attached focused pane must admit selection");
    static_cast<void>(application::terminal::copy_mode::pointer(client, {.pane_id = 1, .kind = application::terminal::copy_mode::CopyPointerKind::release}));
    check(!application::terminal::copy_mode::view(client).state() && transport.count(ClientTag::copy_selection) == 0, "a bare character click must leave without copying");
    check(application::terminal::copy_mode::press(client, {.pane_id = 1, .now_ns = 1}), "the next nearby press must admit word selection");
    transport.reject_copy = true;
    bool rejected = false;

    try {
      static_cast<void>(application::terminal::copy_mode::pointer(client, {.pane_id = 1, .kind = application::terminal::copy_mode::CopyPointerKind::release}));
    } catch (const EncodingError&) {
      rejected = true;
    }

    const auto owner = application::terminal::copy_mode::view(client).pointerOwner();

    check(rejected && owner && !owner->dragging && application::terminal::copy_mode::view(client).state(), "copy failure must preserve highlighting and finish physical capture");
    transport.reject_copy = false;
    check(application::terminal::copy_mode::copy(client, 1), "retained selection must remain copyable after transport recovery");
    client.input(1, "mouse", application::PaneInputSource::mouse);
    check(application::terminal::copy_mode::view(client).state().hasValue(), "mouse reports must preserve highlighting");
    client.input(1, "\x1b[O", application::PaneInputSource::terminal_report);
    check(application::terminal::copy_mode::view(client).state().hasValue(), "focus reports must preserve highlighting");
    client.input(1, "release", application::PaneInputSource::key_release);
    check(!application::terminal::copy_mode::view(client).state() && client.focusedPane()->screen.scroll().offset == 0, "key releases must clear highlighting without changing the viewport");
    check(application::terminal::copy_mode::press(client, {.pane_id = 1, .now_ns = 2}), "a new pointer gesture must be available after typing");
    client.input(1, "text");
    check(!application::terminal::copy_mode::view(client).state() && client.focusedPane()->screen.scroll().offset == history_rows - 1, "typed input must discard highlighting and return to the bottom");
    static_cast<void>(application::terminal::copy_mode::pointer(client, {.pane_id = 1, .kind = application::terminal::copy_mode::CopyPointerKind::release}));
    check(!application::terminal::copy_mode::view(client).pointerOwner(), "typing during a drag must quarantine and finish its later release");
  }

  void editorNavigation() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    application::workbench::navigate(client, PaneDirection::left);
    check(transport.sent.empty(), "navigation without a focused pane must have no effects");
    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    application::workbench::navigate(client, PaneDirection::left);
    check(client.focusedPane()->id == 1, "shell navigation must move to the neighboring split");
    deliver(client, PaneForeground{.pane_id = 1, .name = "nvim"});
    FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = 1}};

    deliverSingleCell(client, frame);

    struct ExpectedKey {
      PaneDirection direction;
      std::string_view legacy;
      std::string_view kitty;
    };

    constexpr ds::Array expected{
        ExpectedKey{.direction = PaneDirection::left, .legacy = "\x08", .kitty = "\x1b[104;5u"},
        ExpectedKey{.direction = PaneDirection::right, .legacy = "\x0c", .kitty = "\x1b[108;5u"},
        ExpectedKey{.direction = PaneDirection::up, .legacy = "\x0b", .kitty = "\x1b[107;5u"},
        ExpectedKey{.direction = PaneDirection::down, .legacy = "\x0a", .kitty = "\x1b[106;5u"},
    };

    for (const auto& key : expected) {
      const auto first_message = transport.sent.size();

      application::workbench::navigate(client, key.direction);
      check(client.focusedPane()->id == 1 && transport.inputSince(first_message) == key.legacy, "Neovim navigation must forward the matching control key without changing panes");
    }

    ++frame.frame_id;
    frame.input_modes.kitty_keyboard_flags = static_cast<Byte>(KittyKeyboardFlag::disambiguate);
    deliverSingleCell(client, frame);
    for (const auto& key : expected) {
      const auto first_message = transport.sent.size();

      application::workbench::navigate(client, key.direction);
      check(client.focusedPane()->id == 1 && transport.inputSince(first_message) == key.kitty, "Neovim navigation must use the pane's current Kitty protocol");
    }

    application::workbench::focusToward(client, PaneDirection::right);
    check(client.focusedPane()->id == 2, "explicit focus must remain available while Neovim is foreground");
    application::workbench::focusPane(client, 1);
    deliver(client, PaneForeground{.pane_id = 1, .name = "Nvim"});
    application::workbench::navigate(client, PaneDirection::right);
    check(client.focusedPane()->id == 2, "editor detection must preserve the original case-sensitive executable name");
  }

  void focusedScrollRouting() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    application::terminal::input::scroll(client, application::ScrollDirection::up);
    check(transport.sent.empty(), "focused scrolling without a pane must have no effects");
    openFirstPane(client, transport);
    constexpr std::uint32_t history_rows = 10;
    constexpr std::uint32_t initial_offset = 4;
    constexpr auto previous_offset = initial_offset - WheelAccumulator::rows_per_line;
    FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = history_rows, .offset = initial_offset}};

    deliverSingleCell(client, frame);
    application::terminal::input::scroll(client, application::ScrollDirection::up);
    check(transport.last<SetPaneViewport>().offset == previous_offset, "an untracked scroll action must move three history rows");
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    check(transport.last<SetPaneViewport>().offset == initial_offset, "opposite focused scroll actions must restore the viewport");
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    check(transport.last<SetPaneViewport>().offset == std::numeric_limits<std::uint32_t>::max() && client.focusedPane()->screen.scroll().offset == history_rows - 1, "scrolling to the bottom asks the runtime to follow the output");

    ++frame.frame_id;
    frame.mouse = {.tracking = MouseTracking::normal, .sgr = true};
    deliverSingleCell(client, frame);
    check(application::terminal::copy_mode::press(client, {.pane_id = 1}), "the scroll fixture must admit a pointer press");
    static_cast<void>(application::terminal::copy_mode::pointer(client, {.pane_id = 1, .kind = application::terminal::copy_mode::CopyPointerKind::release}));
    check(application::terminal::copy_mode::press(client, {.pane_id = 1, .now_ns = 1}), "the scroll fixture must admit word selection");
    static_cast<void>(application::terminal::copy_mode::pointer(client, {.pane_id = 1, .kind = application::terminal::copy_mode::CopyPointerKind::release}));
    const auto viewport_requests = transport.count(ClientTag::set_pane_viewport);
    auto first_message = transport.sent.size();

    application::terminal::input::scroll(client, application::ScrollDirection::up);
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    check(transport.inputSince(first_message) == "\x1b[<64;1;1M\x1b[<65;1;1M", "tracked scroll actions must report one SGR packet at the pane origin");
    check(application::terminal::copy_mode::view(client).state() && client.focusedPane()->screen.scroll().offset == initial_offset && transport.count(ClientTag::set_pane_viewport) == viewport_requests, "mouse reports must preserve highlighting and the scrolled viewport");

    ++frame.frame_id;
    frame.mouse.tracking = MouseTracking::x10;
    frame.input_modes = {.alternate_scroll = true, .alternate_screen = true, .kitty_keyboard_flags = static_cast<Byte>(KittyKeyboardFlag::all_keys)};
    frame.scroll.offset = history_rows - 1;
    deliverSingleCell(client, frame);
    first_message = transport.sent.size();
    application::terminal::input::scroll(client, application::ScrollDirection::up);
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    check(transport.inputSince(first_message) == "\x1b[A\x1b[A\x1b[A\x1b[B\x1b[B\x1b[B", "alternate scrolling must use literal arrows independently of Kitty mode");
    check(application::terminal::copy_mode::view(client).state() && client.focusedPane()->screen.scroll().offset == frame.scroll.offset, "alternate scrolling must preserve highlighting and the bottom viewport");

    ++frame.frame_id;
    frame.scroll.offset = initial_offset;
    deliverSingleCell(client, frame);
    first_message = transport.sent.size();
    application::terminal::input::scroll(client, application::ScrollDirection::up);
    check(transport.inputSince(first_message).empty() && transport.last<SetPaneViewport>().offset == previous_offset, "alternate scrolling away from the bottom must scroll history without child input");
    ++frame.frame_id;
    frame.mouse = {.tracking = MouseTracking::normal};
    deliverSingleCell(client, frame);
    first_message = transport.sent.size();
    application::terminal::input::scroll(client, application::ScrollDirection::up);
    check(transport.inputSince(first_message).empty() && transport.last<SetPaneViewport>().offset == previous_offset, "a tracking mode without SGR must retain the original viewport fallback");
    client.scroll({.pane_id = 1, .rows = std::numeric_limits<std::int64_t>::min()});
    check(client.focusedPane()->screen.scroll().offset == history_rows - 1, "the largest downward scroll must clamp without signed overflow");
    auto bounded_requests = transport.count(ClientTag::set_pane_viewport);

    client.scroll({.pane_id = 1, .rows = std::numeric_limits<std::int64_t>::min()});
    check(transport.count(ClientTag::set_pane_viewport) == bounded_requests, "scrolling beyond the bottom must not send a redundant viewport request");
    client.scroll({.pane_id = 1, .rows = std::numeric_limits<std::int64_t>::max()});
    check(client.focusedPane()->screen.scroll().offset == 0, "the largest upward scroll must clamp to the first history row");
    bounded_requests = transport.count(ClientTag::set_pane_viewport);
    check(application::terminal::copy_mode::enter(client), "the scroll fixture must admit keyboard copy mode");
    client.scroll({.pane_id = 1, .rows = std::numeric_limits<std::int64_t>::min()});
    check(transport.count(ClientTag::set_pane_viewport) == bounded_requests && client.focusedPane()->screen.scroll().offset == 0, "keyboard copy mode must retain exclusive viewport ownership");
    client.disconnected();
    first_message = transport.sent.size();
    application::terminal::input::scroll(client, application::ScrollDirection::down);
    check(transport.sent.size() == first_message, "detached panes must not receive scroll effects");
  }

  void routedLayoutRoundtrip() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::split(client, ClientLayoutAxis::vertical);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    constexpr std::uint16_t original_ratio = 3500;

    client.activeTabMut()->layout.setSplitRatio({.node_index = 0, .ratio = original_ratio});

    ClientCommand command;

    command.request_id = 1;
    command.route = {.id = 1, .generation = 1};
    command.action = ClientAction::layout_get;
    check(deliver(client, command) == application::Change::none, "exporting a layout must not refresh or mutate the window");
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::applied, "layout export must return an applied reply");
    const std::string token{transport.last<CompleteClientCommand>().text};
    const auto preset = LayoutToken::read(token);

    check(preset.focused_pane == 2 && !preset.fullscreen, "export must capture the tab's focus and fullscreen state");

    client.activeTabMut()->layout.setSplitRatio({.node_index = 0, .ratio = PaneLayout::ratio_half});
    application::workbench::focusPane(client, 1);
    application::workbench::toggleFullscreen(client);
    client.setSidebarVisible(false);
    command.request_id = 2;
    command.action = ClientAction::layout_apply;
    command.text = token;
    check(deliver(client, command) == application::Change::model, "importing a layout must invalidate the window projection");
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::applied, "a matching live layout must apply");
    const auto* tab = client.activeTab();

    check(tab->focused_pane == 2 && !tab->fullscreen, "import must restore focus and fullscreen together");
    check(std::get<ClientLayoutSplit>(tab->layout.nodes().front()).ratio == original_ratio, "import must restore split fractions");
    check(!client.configuration.sidebar_visible, "applying the tab tree must preserve the current sidebar preference");
    const auto retained = transport.last<UpdateClientLayout>();

    check(retained.tabs.size() == 1 && retained.tabs.front().focused_pane == 2 && !retained.tabs.front().fullscreen, "the imported state must be retained for reconnects");
    check(client.findPane(2)->attaching && client.findPane(1)->attached, "restored visible panes must enter the existing attachment lifecycle");
  }

  void routedLayoutGuards() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ClientCommand command;

    command.request_id = 1;
    command.route = {.id = 1, .generation = 1};
    command.action = ClientAction::layout_get;
    deliver(client, command);
    const std::string token{transport.last<CompleteClientCommand>().text};

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto split = transport.last<CreatePane>();

    command.request_id = 2;
    command.action = ClientAction::layout_apply;
    command.text = token;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "in-flight pane requests must prevent layout imports");

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    const auto retained_count = transport.count(ClientTag::update_client_layout);

    command.request_id = 3;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "a token cannot hide panes added after it was exported");
    check(client.activeTab()->layout.nodes().size() == 3 && client.activeTab()->focused_pane == 2, "rejected imports must preserve the current tree and focus");
    check(transport.count(ClientTag::update_client_layout) == retained_count, "rejected imports cannot persist partial state");

    auto foreign_location = client.activeTab()->location;

    ++foreign_location.tab_id;
    const ClientTabLayout foreign_tab{
        .location = foreign_location,
        .focused_pane = 2,
        .workspace_active = true,
        .nodes = client.activeTab()->layout.nodes(),
    };

    const ds::Array foreign_tabs{foreign_tab};
    const ClientLayoutSnapshot foreign_snapshot{
        .restored = true,
        .sidebar_visible = true,
        .sidebar_width = 1,
        .active_tab = foreign_location,
        .tabs = foreign_tabs,
    };

    telar::MemoryAdapter adapter{memory};
    ds::String<telar::ConcurrentMemory> foreign_token{adapter};

    LayoutToken::write(foreign_snapshot, foreign_token);
    command.request_id = 4;
    command.text = foreign_token;
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "matching pane identities cannot authorize a token for another tab");
    check(client.activeTab()->focused_pane == 2 && transport.count(ClientTag::update_client_layout) == retained_count, "foreign tokens must leave the active tab untouched");

    ++command.request_id;
    command.text = "zz";
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed && client.activeTab()->layout.nodes().size() == 3, "malformed tokens must not mutate the tab");
  }

  void routedWorkspaceList() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto* focused = client.focusedPane();
    const auto attachments = transport.count(ClientTag::open_pane);
    ClientCommand command{.request_id = 1, .route = {.id = 1, .generation = 1}, .action = ClientAction::workspace_list_collapse};

    check(deliver(client, command) == application::Change::sidebar && client.workspaceListCollapsed(), "routed collapse must update the projection preference");
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::applied, "collapse command must complete as applied");
    check(transport.last<UpdateClientLayout>().workspace_list_collapsed, "collapse preference must be retained by the runtime");

    const auto retained = transport.count(ClientTag::update_client_layout);

    deliver(client, command);
    check(transport.count(ClientTag::update_client_layout) == retained, "repeated collapse must not resend unchanged layout state");
    check(client.focusedPane() == focused && transport.count(ClientTag::open_pane) == attachments, "workspace visibility must preserve terminal focus and attachment ownership");

    command.action = ClientAction::workspace_list_expand;
    command.status = ClientCommandStatus::applied;
    check(deliver(client, command) == application::Change::none && client.workspaceListCollapsed(), "invalid command status must preserve the collapse preference");
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "invalid status must receive a failed completion");

    command.status = ClientCommandStatus::request;
    check(deliver(client, command) == application::Change::sidebar && !client.workspaceListCollapsed(), "routed expand must reveal workspaces again");
    check(!transport.last<UpdateClientLayout>().workspace_list_collapsed, "expanded preference must be retained too");
  }

  void historyReplay() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::history::search(client, "recent");
    const auto query = transport.last<QueryHistory>();

    check(query.author == HistoryAuthorFilter::human && query.match == HistoryMatch::fuzzy, "default history queries must use human authors and fuzzy search");
    check(query.distinct, "history search must list each command once");
    const ds::Array entries{
        HistoryEntry{.id = 1, .pane_id = 1, .command = "echo safe"},
        HistoryEntry{.id = 2, .pane_id = 1, .command = "echo partial", .command_truncated = true},
        HistoryEntry{.id = 3, .pane_id = 1, .command = "echo unsafe\r"},
    };

    deliver(client, HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries});
    const auto reject = [&](std::uint64_t entry_id) {
      const auto input_count = transport.count(ClientTag::pane_input);
      bool rejected = false;

      try {
        application::history::paste(client, entry_id);
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected && transport.count(ClientTag::pane_input) == input_count, "unsafe, stale or unavailable history must queue no terminal bytes");
    };

    reject(2);
    reject(3);
    reject(4);
    auto first_message = transport.sent.size();

    application::history::paste(client, 1);
    check(transport.inputSince(first_message) == "echo safe", "default history submission must paste exact canonical bytes without running");

    auto configuration = client.configuration;

    configuration.history = {.show_agent_commands = true, .enter_runs = true, .match_fts = true};
    application::configuration::configure(client, configuration);
    // Enter runs the paste only where the shell waits for a command: a program in front, as vim
    // or an agent, gets the text alone.
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::running, .shell_foreground = false, .commands = 1});
    first_message = transport.sent.size();
    application::history::paste(client, 1);
    check(transport.inputSince(first_message) == "echo safe", "a running program gets the paste without Enter");
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .commands = 1});
    first_message = transport.sent.size();
    application::history::paste(client, 1);
    check(transport.inputSince(first_message) == "echo safe\r", "configured run must append Enter after the complete paste");
    first_message = transport.sent.size();
    application::history::paste(client, 1, true);
    check(transport.inputSince(first_message) == "echo safe", "alternate submission must invert the configured run preference");

    application::history::search(client, "new query");
    check(application::history::loading(client), "new requests must mark history as loading");
    reject(1);
    deliver(client, HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries});
    check(application::history::loading(client), "stale results must not release current history input authority");
    const auto requested = transport.last<QueryHistory>();

    check(requested.author == HistoryAuthorFilter::all && requested.match == HistoryMatch::fts, "history preferences must select the wire author and match filters");
    deliver(client, RequestFailed{.request_id = requested.request_id, .code = FailureCode::resource_limit, .message = "Query failed"});
    check(!application::history::loading(client), "failed queries must finish their loading indication");
    reject(1);

    transport.reject_history = true;
    bool queue_failed = false;

    try {
      application::history::search(client, "queue failure");
    } catch (const EncodingError&) {
      queue_failed = true;
    }

    check(queue_failed && !application::history::loading(client), "transport failure must release the loading indication");
    reject(1);
  }

  void historyScopesAndVisits() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::history::search(client, "unknown directory", {.scope = HistoryScope::cwd});
    check(transport.last<QueryHistory>().scope == HistoryScope::global, "unavailable scopes must use the original global fallback");
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work/current"});
    const ds::Array workspaces{WorkspaceListEntry{.workspace = 1, .name = "Project", .path = "/work"}};

    deliver(client, WorkspaceList{.revision = 1, .entries = workspaces});
    application::history::search(client, "!   failed", {.scope = HistoryScope::workspace, .author = HistoryAuthorFilter::agent});
    const auto workspace_query = transport.last<QueryHistory>();

    check(workspace_query.query == "failed" && workspace_query.failed_only && workspace_query.author == HistoryAuthorFilter::agent, "the failed prefix must combine with explicit author filters without entering the search text");
    check(workspace_query.scope == HistoryScope::workspace && std::get<std::string_view>(workspace_query.scope_value) == "/work", "workspace scope must resolve the canonical project path");
    application::history::search(client, {}, {.scope = HistoryScope::cwd});
    check(std::get<std::string_view>(transport.last<QueryHistory>().scope_value) == "/work/current", "directory scope must use the focused terminal's reported cwd");
    application::history::search(client, {}, {.scope = HistoryScope::pane});
    const auto query = transport.last<QueryHistory>();

    check(query.scope == HistoryScope::pane && std::get<std::uint64_t>(query.scope_value) == 1, "pane scope must retain the focused pane identity");

    const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "copy exact bytes"}, HistoryEntry{.id = 2, .pane_id = 2, .command = "visit existing pane"}};

    deliver(client, HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries});
    application::history::copy(client, 1);
    check(client.clipboard() == "copy exact bytes", "history copy must use the complete canonical command");
    application::history::remove(client, 1);
    const auto deletion = transport.last<DeleteHistoryCommand>();

    check(deletion.id == 1, "the list shows each command once: deleting one deletes every run of it");

    check(application::history::view(client).rows().size() == entries.size() - 1, "a deleted row leaves the list at once");
    check(deliver(client, HistoryPruned{.request_id = deletion.request_id, .removed = 1}) == application::Change::history, "deletion confirmation must refresh the history projection");
    const auto refreshed = transport.last<QueryHistory>();

    check(refreshed.request_id != query.request_id && refreshed.offset == 0 && refreshed.snapshot_id == 0 && refreshed.scope == HistoryScope::pane, "confirmed deletion must refresh current filters from a new insertion boundary");
    deliver(client, HistoryResults{.request_id = refreshed.request_id, .snapshot_id = 1, .entries = std::span{entries}.last(1)});

    const auto creations = transport.count(ClientTag::create_pane);

    application::history::visit(client, 2);
    const auto opened = transport.last<OpenPane>();

    check(opened.target.kind == PaneTarget::Kind::pane && opened.target.id == 2 && !opened.launch, "visiting an unknown pane must discover its existing runtime location");
    const TabLocation destination{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};

    deliver(client, PaneOpened{.request_id = opened.request_id, .pane_id = 2, .location = destination, .pane_generation = 1});
    check(client.focusedPane()->id == 2 && sameTab(client.activeTab()->location, destination), "a visited pane must select the authoritative workspace and tab");
    check(transport.count(ClientTag::create_pane) == creations, "history navigation must never create a replacement process");
  }

  // A runtime before cqp00012 deletes the one run it is asked for.
  void olderRuntimeDeletesOneRun() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport, telar::handshake::Dialect::cqp00011);
    application::history::search(client, {});
    const auto query = transport.last<QueryHistory>();
    const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "ls"}};

    deliver(client, HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries});
    application::history::remove(client, 1);
    check(transport.count(ClientTag::delete_history) == 1 && transport.count(ClientTag::delete_history_command) == 0, "an older runtime is asked to delete the run");
  }

  void agentNavigationUsesCommittedGenerationsAndExistingPanes() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    constexpr std::uint64_t destination_id = 2;
    constexpr std::uint64_t destination_generation = 9;
    const TabLocation destination{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 2}, .tab_id = 2};
    const ds::Array agents{AgentSnapshotEntry{.pane_id = destination_id, .pane_generation = destination_generation, .location = destination, .pane_index = 1, .workspace_label = "Remote project", .session_title = "Existing agent", .title_source = AgentTitleSource::agent, .title_state = AgentTitleState::ready, .provider = AgentProvider::codex, .provider_name = "codex", .display_name = "Codex", .icon = ">", .status = AgentStatus::working, .sequence = 1}};

    deliver(client, AgentSnapshot{.revision = 1, .entries = agents});
    const auto previous_requests = transport.sent.size();

    check(!application::activity::chooseAgent(client, destination_id, destination_generation - 1), "a stale agent generation must not navigate");
    check(transport.sent.size() == previous_requests, "rejecting an obsolete agent must not send runtime requests");
    check(application::activity::chooseAgent(client, destination_id, destination_generation), "a committed agent must offer navigation");
    const auto opening = transport.last<OpenPane>();

    check(opening.target.kind == PaneTarget::Kind::pane && opening.target.id == destination_id && !opening.launch, "uncached agent navigation must open its existing pane without launching a process");
    deliver(client, PaneOpened{.request_id = opening.request_id, .pane_id = destination_id, .location = destination, .pane_generation = destination_generation});
    check(client.focusedPane()->id == destination_id && sameTab(client.activeTab()->location, destination), "the authoritative open reply must choose the agent's workspace and tab");
    const ds::Array descriptors{PaneDescriptor{.pane_id = destination_id, .lifecycle = PaneLifecycle::running, .pane_generation = destination_generation}};

    deliver(client, TabSnapshot{.request_id = transport.last<RequestTabSnapshot>().request_id, .location = destination, .panes = descriptors});
    const ds::Array tabs{TabDescriptor{.tab_id = destination.tab_id, .pane_count = 1}};

    deliver(client, WorkspaceSnapshot{.request_id = transport.last<RequestWorkspaceSnapshot>().request_id, .workspace = destination.workspace, .name = "Remote project", .tabs = tabs});
    check(!client.requestsPending(), "the first navigation must settle its canonical snapshots before another workspace departure");
    const auto openings = transport.count(ClientTag::open_pane);

    check(application::activity::chooseAgent(client, destination_id, destination_generation), "an already known agent must remain navigable");
    check(transport.count(ClientTag::open_pane) == openings, "known agent navigation must reuse its current local pane");

    auto replacement = agents;

    replacement.atMut(0).pane_generation = destination_generation + 1;
    deliver(client, AgentSnapshot{.revision = 2, .entries = replacement});
    check(!application::activity::chooseAgent(client, destination_id, destination_generation), "a replacement snapshot must retire the previous generation's choice");
    check(application::activity::chooseAgent(client, destination_id, destination_generation + 1), "the replacement agent must remain reachable");
    check(transport.count(ClientTag::open_pane) == openings + 1, "a stale cached pane must be reopened through the runtime instead of focusing the former generation");
  }

  void uncachedHistoryReplay() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    using Storage = application::history::HistoryLimits;
    using Browser = application::history::HistoryLimits;
    constexpr auto command_bytes = Browser::maximum_command_bytes;
    constexpr auto cached_entries = Storage::command_cache_bytes / command_bytes;
    const std::string command(command_bytes, 'x');
    ds::Array<HistoryEntry, cached_entries + 2> entries{};

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries.atMut(index) = {.id = index + 1, .pane_id = 1, .command = command};
    }

    openFirstPane(client, transport);
    application::history::search(client, {});
    deliver(client, HistoryResults{.request_id = transport.last<QueryHistory>().request_id, .snapshot_id = 1, .entries = entries});
    const auto queries = transport.count(ClientTag::query_history);

    application::history::select(client, cached_entries);
    const auto full = transport.last<QueryHistory>();

    check(full.entry_id == entries[cached_entries].id && full.limit == 1 && transport.count(ClientTag::query_history) == queries + 1, "selecting an uncached command must issue one exact-entry query");
    bool rejected = false;
    const auto before_load = transport.count(ClientTag::pane_input);

    try {
      application::history::paste(client, full.entry_id);
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && transport.count(ClientTag::pane_input) == before_load, "a preview must never be sent while full command loading is pending");
    deliver(client, HistoryResults{.request_id = full.request_id, .entries = std::span{entries}.subspan(cached_entries, 1)});
    application::history::copy(client, full.entry_id);
    check(client.clipboard() == command, "copy must use the complete fetched command rather than its preview");
    const auto first_input = transport.sent.size();

    application::history::paste(client, full.entry_id);
    check(transport.inputSince(first_input) == command, "large selected commands must preserve every byte through chunked terminal input");

    application::history::select(client, 0);
    application::history::select(client, cached_entries);
    check(application::history::view(client).canSubmit() && transport.count(ClientTag::query_history) == queries + 1, "returning to the last complete detail must reuse it without another request");
    transport.reject_history = true;
    bool failed = false;

    try {
      application::history::select(client, cached_entries + 1);
    } catch (const EncodingError&) {
      failed = true;
    }

    check(failed && application::history::view(client).state().command_phase == application::history::HistoryPhase::failed && !application::history::view(client).canSubmit(), "a failed exact-entry send must release loading state and keep the preview unactionable");
    check(application::history::view(client).state().phase == application::history::HistoryPhase::ready, "a detail transport failure must preserve the command page");
  }

  void historyQueryBounds() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    std::string query(application::history::HistoryLimits::maximum_query_bytes - 1, 'x');

    query += "é";
    application::history::search(client, query);
    const auto sent = transport.last<QueryHistory>();

    check(sent.query.size() == application::history::HistoryLimits::maximum_query_bytes - 1 && query.starts_with(sent.query), "oversized queries must stop before a split UTF-8 scalar");
  }

  void bracketedHistoryReplay() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const ds::Array cells{Cell{.text = byteView(" ")}};
    constexpr std::size_t encoded_cell_capacity = 64;
    ds::Array<Byte, encoded_cell_capacity> encoded{};
    const ds::Array spans{FrameSpan{.start = 0, .count = 1, .cells = CellRunCodec::encode(cells, encoded.viewMut())}};
    const ds::Array<Byte, 1> flags{};
    PaneFrame frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.cols = 1;
    frame.rows = 1;
    frame.input_modes.bracketed_paste = true;
    frame.scroll.total_rows = 1;
    frame.text_metadata = TextMetadata{.row_flags = flags};
    frame.spans = spans;
    deliver(client, frame);

    application::history::search(client, {});
    const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "echo first\necho\tsecond"}};

    deliver(client, HistoryResults{.request_id = transport.last<QueryHistory>().request_id, .snapshot_id = 1, .entries = entries});
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true});
    const auto first_message = transport.sent.size();

    application::history::paste(client, 1, true);
    check(transport.inputSince(first_message) == "\x1b[200~echo first\necho\tsecond\x1b[201~\r", "multiline run must put Enter after the bracketed-paste terminator");

    const auto clipboard_message = transport.sent.size();

    client.paste(1, "safe\x1b[201~touch pwned\r");
    check(transport.inputSince(clipboard_message) == "\x1b[200~safe [201~touch pwned\r\x1b[201~", "a terminator in pasted text must not close the bracketed paste");
  }

  void routedHostCommands() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    ClientCommand command{.request_id = 1, .route = {.id = 2, .generation = 3}, .action = ClientAction::client_open_history, .text = "borrowed request"};
    std::size_t calls = 0;
    bool should_fail = false;
    const auto handler = [&](const ClientCommand& message, CompleteClientCommand& reply) {
      ++calls;
      check(message.text == command.text, "host handlers must receive the decoded request text");
      if (should_fail) {
        throw std::runtime_error{"Host request failed"};
      }

      reply.status = ClientCommandStatus::admitted;
      reply.text = "host result";
    };

    const auto completions = transport.count(ClientTag::complete_client_command);

    check(deliver(client, command, handler) == application::Change::none && calls == 1, "unhandled core commands must reach the injected host handler");
    const auto reply = transport.last<CompleteClientCommand>();

    check(reply.request_id == command.request_id && reply.route.id == command.route.id && reply.route.generation == command.route.generation, "host replies must preserve request and routing correlation");
    check(reply.status == ClientCommandStatus::admitted && reply.text == "host result", "host handlers must control completion status and result text");
    check(transport.count(ClientTag::complete_client_command) == completions + 1, "host commands must complete exactly once");

    command.action = ClientAction::sidebar_get;
    deliver(client, command, handler);
    check(calls == 1 && transport.last<CompleteClientCommand>().status == ClientCommandStatus::applied, "core commands must not be intercepted by the host handler");
    command.action = ClientAction::client_open_history;
    command.status = ClientCommandStatus::admitted;
    deliver(client, command, handler);
    check(calls == 1 && transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "invalid request status must be rejected before calling the host");

    command.status = ClientCommandStatus::request;
    should_fail = true;
    deliver(client, command, handler);
    check(calls == 2 && transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed && transport.last<CompleteClientCommand>().text == "Host request failed", "host exceptions must become failed protocol completions");
    deliver(client, command);
    check(transport.last<CompleteClientCommand>().status == ClientCommandStatus::failed, "headless sessions must explicitly reject host commands without an injected handler");
  }

  void canonicalRemoval() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::workbench::createTab(client);
    const auto created = transport.last<CreateTab>();
    const TabLocation second{.workspace = created.workspace, .tab_id = 2};

    deliver(client, TabCreated{.request_id = created.request_id, .location = second, .position = 1, .label = "Second", .root_pane_id = 2, .pane_generation = 1});
    application::workbench::selectTab(client, {.workspace = created.workspace, .tab_id = 1});
    const auto late_attach = transport.last<OpenPane>();
    const ds::Array<TabDescriptor, 1> tabs{{{.tab_id = 2, .position = 0, .pane_count = 1, .label = "Second"}}};

    deliver(client, WorkspaceSnapshot{.request_id = 1, .workspace = created.workspace, .name = "Project", .tabs = tabs});
    check(client.tabs.size() == 1 && client.activeTab()->location.tab_id == 2 && client.findPane(1) == nullptr, "canonical workspace snapshots must remove vanished tabs and their screens");
    check(deliver(client, PaneOpened{.request_id = late_attach.request_id, .pane_id = 1, .location = {.workspace = created.workspace, .tab_id = 1}, .created = false, .pane_generation = 1}) == application::Change::none && client.findPane(1) == nullptr, "late attachment replies must not resurrect a closed tab");

    check(deliver(client, ResyncRequired{.workspace = created.workspace, .workspace_closed = true, .previous_workspace = {}}) == application::Change::closed && client.tabs.empty(), "closing the final workspace must release the client projection and "
                                                                                                                                                                                     "close its window");
  }

  void linkContextRevisions() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto original = client.viewVersion();
    const auto original_chrome = client.chromeRevision();

    application::workbench::focusPane(client, 1);
    application::workbench::selectTab(client, client.activeTab()->location);
    deliverSingleCell(client, {.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = 1}});
    deliverSingleCell(client, {.pane_id = 1, .frame_id = 2, .scroll = {.total_rows = 1}});
    deliver(client, PaneTitle{.pane_id = 1, .title = "Changed title"});
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/changed"});
    deliver(client, PaneForeground{.pane_id = 1, .name = "nvim"});
    client.setSidebarVisible(client.configuration.sidebar_visible);
    client.setSidebarWidth(client.configuration.sidebar_width);
    check(client.viewVersion() == original, "frames, pane metadata and unchanged view commands must preserve the gesture context");
    check(client.chromeRevision() > original_chrome, "pane metadata must move the chrome revision the pane headers and tabs read");

    const auto original_size = client.findPane(1)->size;
    auto enlarged = original_size;

    ++enlarged.cols;
    client.resize(1, enlarged);
    const auto resized = client.viewVersion();

    check(resized.viewport > original.viewport, "a changed terminal viewport must invalidate armed links");
    client.resize(1, enlarged);
    check(client.viewVersion() == resized, "an unchanged terminal resize must preserve its gesture revision");
    client.resize(1, original_size);
    check(client.viewVersion().viewport > resized.viewport, "restoring a viewport must not revive the previous gesture context");

    const auto before_sidebar = client.viewVersion();
    const auto visible = client.configuration.sidebar_visible;

    client.setSidebarVisible(!visible);
    client.setSidebarVisible(visible);
    check(client.viewVersion().host > before_sidebar.host, "changing and restoring chrome must keep the intervening invalidation");
    const auto before_configuration = client.viewVersion();
    const auto configuration = client.configuration;

    application::configuration::configure(client, configuration);
    check(client.viewVersion().configuration > before_configuration.configuration, "adopting a configuration must invalidate links even when its geometry matches");

    application::workbench::split(client, ClientLayoutAxis::horizontal);
    const auto split = transport.last<CreatePane>();

    deliver(client, PaneOpened{.request_id = split.request_id, .pane_id = 2, .location = split.location, .created = true, .pane_generation = 1});
    const auto before_focus = client.viewVersion();

    application::workbench::focusPane(client, 1);
    check(client.viewVersion().panes > before_focus.panes, "changing pane focus must invalidate armed links");
    application::workbench::focusPane(client, 2);
    check(client.viewVersion().panes > before_focus.panes + 1, "restoring focus must not restore its former gesture revision");
  }

  const telar::testing::Case case_session_lifecycle{"session.session_lifecycle", sessionLifecycle};
  const telar::testing::Case case_pending_attachment_keeps_the_latest_viewport{"session.pending_attachment_keeps_the_latest_viewport", pendingAttachmentKeepsTheLatestViewport};
  const telar::testing::Case case_detached_tab_foregrounds_and_agent_titles{"session.detached_tab_foregrounds_and_agent_titles", detachedTabForegroundsAndAgentTitles};
  const telar::testing::Case case_configured_window_titles{"session.configured_window_titles", configuredWindowTitles};
  const telar::testing::Case case_restored_layout_and_failure{"session.restored_layout_and_failure", restoredLayoutAndFailure};
  const telar::testing::Case case_stale_history{"session.stale_history", staleHistory};
  const telar::testing::Case case_routed_commands{"session.routed_commands", routedCommands};
  const telar::testing::Case case_routed_sidebar_resize{"session.routed_sidebar_resize", routedSidebarResize};
  const telar::testing::Case case_routed_copy_range{"session.routed_copy_range", routedCopyRange};
  const telar::testing::Case case_pointer_selection_lifecycle{"session.pointer_selection_lifecycle", pointerSelectionLifecycle};
  const telar::testing::Case case_editor_navigation{"session.editor_navigation", editorNavigation};
  const telar::testing::Case case_focused_scroll_routing{"session.focused_scroll_routing", focusedScrollRouting};
  const telar::testing::Case case_routed_layout_roundtrip{"session.routed_layout_roundtrip", routedLayoutRoundtrip};
  const telar::testing::Case case_routed_layout_guards{"session.routed_layout_guards", routedLayoutGuards};
  const telar::testing::Case case_routed_workspace_list{"session.routed_workspace_list", routedWorkspaceList};
  const telar::testing::Case case_routed_host_commands{"session.routed_host_commands", routedHostCommands};
  const telar::testing::Case case_history_replay{"session.history_replay", historyReplay};
  const telar::testing::Case case_history_scopes_and_visits{"session.history_scopes_and_visits", historyScopesAndVisits};
  const telar::testing::Case case_older_runtime_deletes_one_run{"session.older_runtime_deletes_one_run", olderRuntimeDeletesOneRun};
  const telar::testing::Case case_agent_navigation_uses_committed_generations_and_existing_panes{"session.agent_navigation_uses_committed_generations_and_existing_panes", agentNavigationUsesCommittedGenerationsAndExistingPanes};
  const telar::testing::Case case_uncached_history_replay{"session.uncached_history_replay", uncachedHistoryReplay};
  const telar::testing::Case case_history_query_bounds{"session.history_query_bounds", historyQueryBounds};
  const telar::testing::Case case_bracketed_history_replay{"session.bracketed_history_replay", bracketedHistoryReplay};
  const telar::testing::Case case_canonical_removal{"session.canonical_removal", canonicalRemoval};
  const telar::testing::Case case_link_context_revisions{"session.link_context_revisions", linkContextRevisions};

}
