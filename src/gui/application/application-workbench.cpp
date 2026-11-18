module telar.gui.application;

import std;

import :access;
import telar.base.memory.allocators;
import telar.base.text;
import telar.config.runtime;
import telar.gui.features.activity;
import telar.gui.features.terminal.copy_mode;
import telar.gui.features.workbench;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.model;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.ds;

namespace telar::gui::application::workbench {

  namespace feature = features::workbench;

  namespace {

    using RequestKind = Access::RequestKind;

    [[nodiscard]] bool paneOperationPending(const Session& session) noexcept {
      return std::ranges::any_of(Access::requests(session), [](const auto& request) {
        return request.kind == RequestKind::split || request.kind == RequestKind::close_pane;
      });
    }

    bool requestSplit(Session& session, std::uint64_t pane_id, ClientLayoutAxis axis, Launch launch) {
      auto* tab = session.activeTab();
      const auto* pane = session.findPane(pane_id);
      if (paneOperationPending(session) || tab == nullptr || pane == nullptr || !pane->attached || pane->exited || !sameTab(pane->location, tab->location)) {
        return false;
      }

      const auto sizes = feature::splitSizes(Access::workbench(session), *tab, pane_id, axis);
      if (!sizes) {
        return false;
      }

      const auto request_id = Access::pending(session, RequestKind::split, pane_id, axis);
      auto& registration = Access::lastPending(session);

      registration.location = tab->location;
      registration.size = sizes->added;
      const auto registered = registration;

      launch.cwd_source = pane_id;
      try {
        Access::send(session, PaneResize{.pane_id = pane_id, .size = sizes->existing});
        Access::send(session, CreatePane{.request_id = request_id, .location = tab->location, .size = sizes->added, .launch = launch});
      } catch (...) {
        Access::complete(session, request_id);
        recoverSplit(session, registered.location, registered.pane_id);
        throw;
      }

      return true;
    }

    TabCreationOutcome requestTab(Session& session, std::string_view label, std::span<const std::string_view> arguments) {
      if (tabOperationPending(session)) {
        return TabCreationOutcome::busy;
      }

      constexpr std::size_t maximum_label_bytes = 128;

      DisplayText16<maximum_label_bytes>::validate(label);
      const auto* tab = session.activeTab();
      const auto* pane = session.focusedPane();
      if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(pane->location, tab->location)) {
        return TabCreationOutcome::unavailable;
      }

      auto launch = Access::defaultLaunch(session);

      launch.cwd_source = pane->id;
      if (!arguments.empty()) {
        launch.arguments = arguments;
      }

      Access::sendTabOperation(session, RequestKind::create_tab, CreateTab{.workspace = tab->location.workspace, .label = label, .size = feature::launchSize(Access::workbench(session)), .launch = launch});

      return TabCreationOutcome::requested;
    }

    // Every pane of the tab in `preset` is in its layout, and no other.
    void validateMembership(const Session& session, const feature::TabLayoutPreset& preset) {
      std::size_t leaves = 0;

      for (const auto& node : preset.layout.nodes()) {
        if (const auto* leaf = std::get_if<ClientLayoutPane>(&node)) {
          const auto* pane = session.findPane(leaf->pane_id);
          if (pane == nullptr || !sameTab(pane->location, preset.location)) {
            throw EncodingError{"Layout token pane does not belong to its tab"};
          }

          ++leaves;
        }
      }

      const auto members = std::ranges::count_if(session.panes(), [&](const auto& pane) {
        return sameTab(pane->location, preset.location);
      });
      if (std::cmp_not_equal(leaves, members)) {
        throw EncodingError{"Layout token pane membership has changed"};
      }
    }

  }

  // ---- the area the panes share -------------------------------------------------------------

  const WorkbenchGeometry& geometry(const Session& session) noexcept {
    return feature::geometry(Access::workbench(session));
  }

  void setGeometry(Session& session, WorkbenchGeometry geometry) noexcept {
    if (feature::place(Access::workbench(session), geometry)) {
      ++Access::viewVersion(session).viewport;
    }
  }

  void reserveBottom(Session& session, ds::Option<PaneBottomReservation> reservation) {
    auto& state = Access::workbench(session);
    const auto reserved = feature::reserve(state, reservation, session.tabs());

    if (reserved.changed) {
      ++Access::viewVersion(session).viewport;
    }

    if (reserved.resize) {
      if (auto* tab = session.activeTab()) {
        resizeVisible(session, *tab);
      }

      feature::resized(state);
    }
  }

  // ---- tabs ---------------------------------------------------------------------------------

  void selectTab(Session& session, TabLocation location) {
    auto& active_tab = Access::activeTab(session);
    auto& view_version = Access::viewVersion(session);

    if (!active_tab || !sameTab(*active_tab, location)) {
      ++view_version.active_tab;
      if (!active_tab || !sameWorkspace(active_tab->workspace, location.workspace)) {
        ++view_version.workspace;
      }
    }

    if (const auto* copy_pane = terminal::copy_mode::pane(session); copy_pane != nullptr && !sameTab(copy_pane->location, location)) {
      features::terminal::copy_mode::close(Access::copyMode(session));
    }

    active_tab = location;
    auto& tab = Access::ensureTab(session, location);

    for (const auto& candidate : session.tabs()) {
      if (sameWorkspace(candidate->location.workspace, location.workspace)) {
        candidate->workspace_active = candidate.get() == &tab;
      }
    }

    if (!tab.loaded && !tab.loading) {
      tab.loading = true;
      Access::requestSnapshot(session, RequestTabSnapshot{.location = location});
    }

    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

  void selectTabAt(Session& session, std::size_t index) {
    if (const auto location = feature::tabAt(session.tabs(), Access::activeTab(session), index)) {
      selectTab(session, *location);
    }
  }

  void selectTabBeside(Session& session, std::int32_t offset) {
    if (const auto location = feature::tabBeside(session.tabs(), Access::activeTab(session), offset)) {
      selectTab(session, *location);
    }
  }

  TabCreationOutcome createTab(Session& session, std::string_view label) {
    return requestTab(session, label, {});
  }

  TabCreationOutcome createCommandTab(Session& session, const runtime::config::CommandTabView& command) {
    if (command.count == 0 || command.count > command.arguments.size()) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    return requestTab(session, command.label(), command.argv());
  }

  void renameTab(Session& session, std::string_view label) {
    if (const auto location = Access::activeTab(session); location && !tabOperationPending(session)) {
      Access::sendTabOperation(session, RequestKind::rename_tab, RenameTab{.location = *location, .label = label});
    }
  }

  void closeTab(Session& session, TabLocation location) {
    if (!tabOperationPending(session)) {
      Access::sendTabOperation(session, RequestKind::close_tab, CloseTab{.location = location});
    }
  }

  void moveTab(Session& session, TabMoveDirection direction, ds::Option<std::uint64_t> relative_to) {
    if (const auto location = Access::activeTab(session)) {
      static_cast<void>(dropTab(session, {.location = *location, .direction = direction, .relative_to = relative_to}));
    }
  }

  bool dropTab(Session& session, const TabDragMove& move) {
    const auto& active_tab = Access::activeTab(session);
    const auto tabs = feature::Tabs{session.tabs()};
    if (tabOperationPending(session) || !active_tab || !sameWorkspace(active_tab->workspace, move.location.workspace) || feature::find(tabs, move.location) == nullptr) {
      return false;
    }

    if (move.relative_to && (*move.relative_to == move.location.tab_id || feature::find(tabs, {.workspace = move.location.workspace, .tab_id = *move.relative_to}) == nullptr)) {
      return false;
    }

    Access::sendTabOperation(session, RequestKind::move_tab, MoveTab{.location = move.location, .direction = move.direction, .relative_to = move.relative_to});

    return true;
  }

  bool tabOperationPending(const Session& session) noexcept {
    return std::ranges::any_of(Access::requests(session), [](const auto& request) {
      return request.kind == RequestKind::create_tab || request.kind == RequestKind::rename_tab || request.kind == RequestKind::move_tab || request.kind == RequestKind::close_tab;
    });
  }

  // ---- panes --------------------------------------------------------------------------------

  void focusPane(Session& session, std::uint64_t pane_id) {
    auto* pane = session.findPane(pane_id);
    if (pane == nullptr) {
      const auto& agents = session.agents();
      const auto agent = std::find_if(agents.begin(), agents.end(), [&](const auto& entry) {
        return entry.pane_id == pane_id;
      });
      if (agent == agents.end()) {
        return;
      }

      // The agent's row is read before the pane table can grow.
      const auto location = agent->location;
      const auto generation = agent->pane_generation;

      pane = &Access::ensurePane(session, pane_id, location);
      pane->generation = generation;
    }

    auto& tab = Access::ensureTab(session, pane->location);

    setFocus(session, tab, pane_id);
    selectTab(session, pane->location);
    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

  void focusToward(Session& session, PaneDirection direction) {
    if (const auto target = neighbor(session, direction); target != 0) {
      focusPane(session, target);
    }
  }

  void navigate(Session& session, PaneDirection direction) {
    const auto* pane = session.focusedPane();
    if (pane == nullptr || pane->foreground != "nvim") {
      focusToward(session, direction);

      return;
    }

    constexpr auto characters = ds::Array<std::pair<PaneDirection, char>, 4>{{
        {PaneDirection::left, 'h'},
        {PaneDirection::right, 'l'},
        {PaneDirection::up, 'k'},
        {PaneDirection::down, 'j'},
    }};

    const auto* const found = std::ranges::find(characters, direction, &decltype(characters)::value_type::first);
    if (found == characters.end()) {
      return;
    }

    const TerminalKey key{.codepoint = static_cast<std::uint32_t>(found->second), .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
    KeyEncoder encoder;

    session.input(pane->id, encoder.encode(key, pane->screen.modes()));
  }

  bool resizeToward(Session& session, PaneDirection direction) {
    auto* tab = session.activeTab();
    if (tab == nullptr || !feature::resize(Access::workbench(session), *tab, direction)) {
      return false;
    }

    ++Access::viewVersion(session).panes;
    retainLayout(session);

    return true;
  }

  bool split(Session& session, ClientLayoutAxis axis) {
    const auto* tab = session.activeTab();
    if (tab == nullptr) {
      return false;
    }

    return requestSplit(session, tab->focused_pane, axis, Access::defaultLaunch(session));
  }

  bool closePane(Session& session, std::uint64_t pane_id) {
    if (paneOperationPending(session)) {
      return false;
    }

    Access::sendRegistered(session, RequestKind::close_pane, ClosePane{0, pane_id}, pane_id);

    return true;
  }

  void toggleFullscreen(Session& session) {
    if (auto* tab = session.activeTab()) {
      ++Access::viewVersion(session).panes;
      tab->fullscreen = !tab->fullscreen;
      Access::synchronizeAttachments(session);
      retainLayout(session);
    }
  }

  void retainLayout(Session& session) {
    const auto& active_tab = Access::activeTab(session);
    if (!session.ready() || !active_tab) {
      return;
    }

    ds::Array<ClientTabLayout, feature::maximum_tabs> layouts;
    std::size_t count = 0;
    std::size_t retained_nodes = 0;
    const auto append = [&](const Tab<Memory>& tab) {
      if (!tab.loaded || tab.layout.nodes().empty() || tab.focused_pane == 0 || retained_nodes + tab.layout.nodes().size() > Session::maximum_retained_layout_nodes) {
        return;
      }

      layouts.atMut(count++) = {tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, tab.layout.nodes()};
      retained_nodes += tab.layout.nodes().size();
    };

    if (const auto* active = session.activeTab()) {
      append(*active);
    }

    for (const auto& tab : session.tabs()) {
      if (!sameTab(tab->location, *active_tab)) {
        append(*tab);
      }
    }

    const auto active_found = std::any_of(layouts.begin(), layouts.begin() + count, [&](const auto& layout) {
      return sameTab(layout.location, *active_tab);
    });
    if (active_found) {
      Access::send(session, UpdateClientLayout{.sidebar_visible = Access::configuration(session).sidebar_visible, .sidebar_width = Access::sidebarColumns(session), .workspace_list_collapsed = session.workspaceListCollapsed(), .active_tab = *active_tab, .tabs = {layouts.data(), count}});
    }
  }

  // ---- workspaces ---------------------------------------------------------------------------

  bool selectWorkspace(Session& session, WorkspaceLocation location) {
    const auto& workspaces = session.workspaceList();
    const auto& active_tab = Access::activeTab(session);
    if (!session.ready() || workspaces.revision() == 0 || session.requestsPending() || location.kind != WorkspaceLocation::Kind::workspace || workspaces.indexOf(location.id) == workspaces.entries().size() || (active_tab && sameWorkspace(active_tab->workspace, location))) {
      return false;
    }

    const auto bookmark = feature::bookmark(Access::workbench(session), location);
    const auto target = bookmark ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = *bookmark} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = location.id};

    Access::handoffWorkspace(session, target, location.id);

    return true;
  }

  void selectWorkspaceAt(Session& session, std::size_t index) {
    const auto projects = session.workspaceList().projects();
    if (index < projects.size()) {
      static_cast<void>(selectWorkspace(session, projects[index].location));
    }
  }

  void createWorkspace(Session& session, WorkspaceDraft draft) {
    auto launch = Access::defaultLaunch(session);

    if (!draft.path.empty()) {
      launch.cwd = draft.path;
    } else if (const auto* pane = session.focusedPane(); pane != nullptr) {
      launch.cwd_source = pane->id;
    }

    Access::open(session, RequestKind::create_workspace, CreateWorkspace{.size = feature::launchSize(Access::workbench(session)), .name = draft.name, .create_cwd = draft.create_directory, .launch = launch});
  }

  void renameWorkspace(Session& session, std::string_view name) {
    if (const auto location = Access::activeTab(session)) {
      Access::send(session, RenameWorkspace{Access::nextRequest(session), location->workspace, name});
    }
  }

  bool openWorktree(Session& session, std::uint64_t identity) {
    const auto* row = session.workspaceList().worktree(identity);
    if (!session.ready() || row == nullptr || !row->workspace) {
      return false;
    }

    const auto workspace = *row->workspace;

    return selectWorkspace(session, {.kind = WorkspaceLocation::Kind::workspace, .id = workspace});
  }

  bool leaveWorktree(Session& session) {
    const auto& active_tab = Access::activeTab(session);
    if (!session.ready() || !active_tab || active_tab->workspace.kind != WorkspaceLocation::Kind::workspace) {
      return false;
    }

    const auto* row = session.workspaceList().worktreeOfWorkspace(active_tab->workspace.id);
    if (row == nullptr) {
      return false;
    }

    const auto source = row->source;

    return selectWorkspace(session, {.kind = WorkspaceLocation::Kind::workspace, .id = source});
  }

  std::size_t forgetGoneWorktrees(Session& session) {
    if (!session.ready()) {
      return 0;
    }

    std::size_t sent = 0;

    for (const auto& row : session.workspaceList().worktrees()) {
      if (row.state != WorktreeState::gone || row.workspace) {
        continue;
      }

      if (Access::requests(session).size() == Session::maximum_pending) {
        break;
      }

      Access::sendRegistered(session, RequestKind::forget_worktree, ForgetWorktree{.request_id = 0, .worktree = row.id});

      ++sent;
    }

    return sent;
  }

  // ---- what the session and the other use cases hand the workbench --------------------------

  void visit(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> generation) {
    if (!session.ready() || !session.presented()) {
      return;
    }

    const auto* pane = session.findPane(pane_id);
    const auto& active_tab = Access::activeTab(session);
    if (pane != nullptr && (!generation || pane->generation == *generation) && active_tab && sameWorkspace(pane->location.workspace, active_tab->workspace)) {
      focusPane(session, pane_id);
    } else if (!session.requestsPending()) {
      Access::handoffPane(session, pane_id, features::activity::workspaceOf(session.agents(), session.paneList(), pane_id, generation));
    }
  }

  void launchTab(Session& session, std::span<const std::string_view> arguments) {
    auto launch = Access::defaultLaunch(session);

    launch.arguments = arguments;
    if (session.activeTab() != nullptr) {
      static_cast<void>(requestTab(session, {}, launch.arguments));
    } else {
      Access::open(session, RequestKind::open_default, OpenPane{.size = feature::launchSize(Access::workbench(session)), .launch = launch});
    }
  }

  void launchSplit(Session& session, std::uint64_t pane_id, std::span<const std::string_view> arguments) {
    auto launch = Access::defaultLaunch(session);

    launch.arguments = arguments;
    if (!requestSplit(session, pane_id, ClientLayoutAxis::horizontal, launch)) {
      throw std::runtime_error{"PaneSplitUnavailable"};
    }
  }

  void setFocus(Session& session, Tab<Memory>& tab, std::uint64_t pane_id) {
    if (tab.focused_pane != pane_id) {
      tab.focused_pane = pane_id;
      ++Access::viewVersion(session).panes;
    }

    terminal::graphics::focus(session, pane_id);
  }

  void resizeVisible(Session& session, Tab<Memory>& tab) {
    feature::arrange(Access::workbench(session), tab, [&](std::uint64_t pane_id, TerminalSize size) {
      session.resize(pane_id, size);
    });
  }

  void recoverSplit(Session& session, TabLocation location, std::uint64_t pane_id) {
    auto* tab = session.activeTab();
    const auto* pane = session.findPane(pane_id);
    if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(tab->location, location) || !sameTab(pane->location, location)) {
      return;
    }

    feature::arrange(Access::workbench(session), *tab, [&](std::uint64_t placed, TerminalSize size) {
      if (placed == pane_id) {
        Access::send(session, PaneResize{.pane_id = pane_id, .size = size});
      }
    });
  }

  std::uint64_t neighbor(Session& session, PaneDirection direction) {
    auto* tab = session.activeTab();
    if (tab == nullptr) {
      return 0;
    }

    return feature::neighbor(Access::workbench(session), *tab, direction);
  }

  std::string_view exportLayout(Session& session) {
    const auto* tab = session.activeTab();
    if (tab == nullptr || tab->focused_pane == 0) {
      throw EncodingError{"No active tab layout"};
    }

    const ClientTabLayout saved_tab{
        .location = tab->location,
        .focused_pane = tab->focused_pane,
        .fullscreen = tab->fullscreen,
        .workspace_active = true,
        .nodes = tab->layout.nodes(),
    };

    const ds::Array tabs{saved_tab};
    const ClientLayoutSnapshot snapshot{
        .restored = true,
        .sidebar_visible = Access::configuration(session).sidebar_visible,
        .sidebar_width = Access::sidebarColumns(session),
        .workspace_list_collapsed = session.workspaceListCollapsed(),
        .active_tab = tab->location,
        .tabs = tabs,
    };

    return feature::LayoutToken::write(snapshot, Access::commandResponse(session));
  }

  void importLayout(Session& session, std::string_view token) {
    auto* tab = session.activeTab();
    if (session.requestsPending() || (tab != nullptr && tab->loading)) {
      throw EncodingError{"Client has requests in flight"};
    }

    if (tab == nullptr) {
      throw EncodingError{"No active tab layout"};
    }

    const auto preset = feature::LayoutToken::read(token);
    if (!sameTab(preset.location, tab->location)) {
      throw EncodingError{"Layout token belongs to another tab"};
    }

    validateMembership(session, preset);
    tab->layout.restore(preset.layout.nodes());
    ++Access::viewVersion(session).panes;
    tab->focused_pane = preset.focused_pane;
    tab->fullscreen = preset.fullscreen;
    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

}
