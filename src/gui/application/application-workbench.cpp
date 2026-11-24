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
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.ds;

namespace telar::gui::application::workbench {

  namespace feature = features::workbench;

  namespace {

    using RequestKind = Access::RequestKind;

    [[nodiscard]] bool paneOperationPending(const Session& session) noexcept {
      return std::ranges::any_of(session.link.requests(), [](const auto& request) {
        return request.kind == RequestKind::split || request.kind == RequestKind::close_pane;
      });
    }

    // What a new pane is: a terminal that runs the session's launch or `arguments`, or an
    // editor on `files`.
    struct NewPane {
      ds::Option<std::span<const std::string_view>> arguments = ds::none;
      bool editor = false;
      std::span<const std::string_view> files;
      // Where an editor's cursor starts in its first file, counted from one.
      std::uint32_t line = 0;
      std::uint32_t column = 0;
      // Where a terminal starts, instead of where the pane it splits works.
      std::string_view directory;
      // The windows of an explorer, when the pane is one.
      const ExplorerLayout* explorer = nullptr;
    };

    // Splits pane `pane_id` along `axis`, the new pane being `added`.
    bool requestSplit(Session& session, std::uint64_t pane_id, ClientLayoutAxis axis, const NewPane& added) {
      auto* tab = activeTabMut(session.tabs, session.active_tab);
      const auto* pane = findPane(session.panes, pane_id);
      if (paneOperationPending(session) || tab == nullptr || pane == nullptr || !pane->attached || pane->exited || !sameTab(pane->location, tab->location)) {
        return false;
      }

      const auto sizes = feature::splitSizes(session.workbench, *tab, pane_id, axis);
      if (!sizes) {
        return false;
      }

      const auto request_id = session.link.pending(RequestKind::split, pane_id, axis);
      auto& registration = session.link.lastPending();

      registration.location = tab->location;
      registration.size = sizes->added;
      const auto registered = registration;

      auto launch = session.launch_defaults.launch();

      launch.cwd_source = pane_id;
      if (added.arguments) {
        launch.arguments = *added.arguments;
      }

      if (!added.directory.empty()) {
        launch.cwd = added.directory;
        launch.cwd_source = 0;
      }

      try {
        session.link.send(PaneResize{.pane_id = pane_id, .size = sizes->existing});
        if (added.explorer != nullptr) {
          session.link.send(CreateExplorerPane{.request_id = request_id, .location = tab->location, .size = sizes->added, .layout = *added.explorer});
        } else if (added.editor) {
          // The editor starts where the pane it splits works.
          session.link.send(CreateNvimPane{.request_id = request_id, .location = tab->location, .size = sizes->added, .cwd = pane->cwd, .files = added.files, .line = added.line, .column = added.column});
        } else {
          session.link.send(CreatePane{.request_id = request_id, .location = tab->location, .size = sizes->added, .launch = launch});
        }
      } catch (...) {
        session.link.complete(request_id);
        recoverSplit(session, registered.location, registered.pane_id);
        throw;
      }

      return true;
    }

    TabCreationOutcome requestTab(Session& session, std::string_view label, const NewPane& added) {
      if (tabOperationPending(session)) {
        return TabCreationOutcome::busy;
      }

      constexpr std::size_t maximum_label_bytes = 128;

      DisplayText16<maximum_label_bytes>::validate(label);
      const auto* tab = activeTab(session.tabs, session.active_tab);
      const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
      if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(pane->location, tab->location)) {
        return TabCreationOutcome::unavailable;
      }

      auto launch = session.launch_defaults.launch();

      launch.cwd_source = pane->id;
      if (added.arguments && !added.arguments->empty()) {
        launch.arguments = *added.arguments;
      }

      if (added.editor) {
        session.link.sendTabOperation(RequestKind::create_tab, CreateNvimPane{.location = tab->location, .new_tab = true, .size = feature::launchSize(session.workbench), .cwd = pane->cwd, .files = added.files});
      } else {
        session.link.sendTabOperation(RequestKind::create_tab, CreateTab{.workspace = tab->location.workspace, .label = label, .size = feature::launchSize(session.workbench), .launch = launch});
      }

      return TabCreationOutcome::requested;
    }

    // Every pane of the tab in `preset` is in its layout, and no other.
    void validateMembership(const Session& session, const feature::TabLayoutPreset& preset) {
      std::size_t leaves = 0;

      for (const auto& node : preset.layout.nodes()) {
        if (const auto* leaf = std::get_if<ClientLayoutPane>(&node)) {
          const auto* pane = findPane(session.panes, leaf->pane_id);
          if (pane == nullptr || !sameTab(pane->location, preset.location)) {
            throw EncodingError{"Layout token pane does not belong to its tab"};
          }

          ++leaves;
        }
      }

      const auto members = std::ranges::count_if(session.panes, [&](const auto& pane) {
        return sameTab(pane->location, preset.location);
      });
      if (std::cmp_not_equal(leaves, members)) {
        throw EncodingError{"Layout token pane membership has changed"};
      }
    }

  }

  // ---- the area the panes share -------------------------------------------------------------

  const WorkbenchGeometry& geometry(const Session& session) noexcept {
    return feature::geometry(session.workbench);
  }

  void setGeometry(Session& session, WorkbenchGeometry geometry) noexcept {
    if (feature::place(session.workbench, geometry)) {
      ++session.view_version.viewport;
    }
  }

  void reserveBottom(Session& session, ds::Option<PaneBottomReservation> reservation) {
    auto& state = session.workbench;
    const auto reserved = feature::reserve(state, reservation, Access::tabsMut(session));

    if (reserved.changed) {
      ++session.view_version.viewport;
    }

    if (reserved.resize) {
      resizeVisible(session);

      feature::resized(state);
    }
  }

  // ---- tabs ---------------------------------------------------------------------------------

  void selectTab(Session& session, TabLocation location) {
    auto& active_tab = session.active_tab;
    auto& view_version = session.view_version;

    if (!active_tab || !sameTab(*active_tab, location)) {
      ++view_version.active_tab;
      if (!active_tab || !sameWorkspace(active_tab->workspace, location.workspace)) {
        ++view_version.workspace;
      }
    }

    if (const auto* copy_pane = terminal::copy_mode::pane(session.copy_mode, session.panes); copy_pane != nullptr && !sameTab(copy_pane->location, location)) {
      features::terminal::copy_mode::close(session.copy_mode);
    }

    active_tab = location;
    auto& tab = Access::ensureTab(session, location);

    for (auto& candidate : Access::tabsMut(session)) {
      if (sameWorkspace(candidate->location.workspace, location.workspace)) {
        candidate.getMut().workspace_active = &candidate.get() == &tab;
      }
    }

    if (!tab.loaded && !tab.loading) {
      tab.loading = true;
      session.link.sendSnapshotRequest(RequestTabSnapshot{.location = location});
    }

    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

  void selectTabAt(Session& session, std::size_t index) {
    if (const auto location = feature::tabAt(session.tabs, session.active_tab, index)) {
      selectTab(session, *location);
    }
  }

  void selectTabBeside(Session& session, std::int32_t offset) {
    if (const auto location = feature::tabBeside(session.tabs, session.active_tab, offset)) {
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

    return requestTab(session, command.label(), {.arguments = command.argv()});
  }

  void renameTab(Session& session, std::string_view label) {
    if (const auto location = session.active_tab; location && !tabOperationPending(session)) {
      session.link.sendTabOperation(RequestKind::rename_tab, RenameTab{.location = *location, .label = label});
    }
  }

  void closeTab(Session& session, TabLocation location) {
    if (!tabOperationPending(session)) {
      session.link.sendTabOperation(RequestKind::close_tab, CloseTab{.location = location});
    }
  }

  void moveTab(Session& session, TabMoveDirection direction, ds::Option<std::uint64_t> relative_to) {
    if (const auto location = session.active_tab) {
      static_cast<void>(dropTab(session, {.location = *location, .direction = direction, .relative_to = relative_to}));
    }
  }

  bool dropTab(Session& session, const TabDragMove& move) {
    const auto& active_tab = session.active_tab;
    const auto tabs = feature::Tabs{session.tabs};
    if (tabOperationPending(session) || !active_tab || !sameWorkspace(active_tab->workspace, move.location.workspace) || feature::find(tabs, move.location) == nullptr) {
      return false;
    }

    if (move.relative_to && (*move.relative_to == move.location.tab_id || feature::find(tabs, {.workspace = move.location.workspace, .tab_id = *move.relative_to}) == nullptr)) {
      return false;
    }

    session.link.sendTabOperation(RequestKind::move_tab, MoveTab{.location = move.location, .direction = move.direction, .relative_to = move.relative_to});

    return true;
  }

  bool tabOperationPending(const Session& session) noexcept {
    return std::ranges::any_of(session.link.requests(), [](const auto& request) {
      return request.kind == RequestKind::create_tab || request.kind == RequestKind::rename_tab || request.kind == RequestKind::move_tab || request.kind == RequestKind::close_tab;
    });
  }

  // ---- panes --------------------------------------------------------------------------------

  void focusPane(Session& session, std::uint64_t pane_id) {
    auto* pane = findPaneMut(session.panes, pane_id);
    if (pane == nullptr) {
      const auto& agents = session.agents();
      const auto* const agent = std::ranges::find_if(agents, [&](const auto& entry) {
        return entry.pane_id == pane_id;
      });

      // A pane the session never showed is one its runtime lists: an agent's, or any other.
      const auto listed = session.paneList();
      const auto known = std::ranges::find(listed, pane_id, &ListedPane::pane_id);

      if (agent == agents.end() && known == listed.end()) {
        return;
      }

      // The row is read before the pane table can grow.
      const auto location = agent != agents.end() ? agent->location : known->location;
      const auto generation = agent != agents.end() ? agent->pane_generation : known->pane_generation;

      pane = &Access::ensurePane(session, pane_id, location);
      pane->generation = generation;
    }

    const auto location = pane->location;

    static_cast<void>(Access::ensureTab(session, location));
    setFocus(session, location, pane_id);
    selectTab(session, location);
    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

  void focusToward(Session& session, PaneDirection direction) {
    if (const auto target = neighbor(session, direction); target != 0) {
      focusPane(session, target);
    }
  }

  void navigate(Session& session, PaneDirection direction) {
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    // An editor pane is asked for the window on that side, and says when it has none.
    if (pane != nullptr && nvim::editor(session, pane->id) != nullptr) {
      nvim::navigate(session, pane->id, direction);

      return;
    }

    if (pane == nullptr || pane->foreground != "nvim") {
      focusToward(session, direction);

      return;
    }

    constexpr auto characters = ds::Array<std::pair<PaneDirection, char>, 4>{
        std::pair{PaneDirection::left, 'h'},
        std::pair{PaneDirection::right, 'l'},
        std::pair{PaneDirection::up, 'k'},
        std::pair{PaneDirection::down, 'j'},
    };

    const auto* const found = std::ranges::find(characters, direction, &decltype(characters)::value_type::first);
    if (found == characters.end()) {
      return;
    }

    const TerminalKey key{.codepoint = static_cast<std::uint32_t>(found->second), .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
    KeyEncoder encoder;

    session.input(pane->id, encoder.encode(key, pane->screen.modes()));
  }

  bool resizeToward(Session& session, PaneDirection direction) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
    if (tab == nullptr || !feature::resize(session.workbench, *tab, direction)) {
      return false;
    }

    ++session.view_version.panes;
    retainLayout(session);

    return true;
  }

  bool dragDivider(Session& session, const DividerDrag& drag) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
    if (tab == nullptr || tab->fullscreen || !std::isfinite(drag.x) || !std::isfinite(drag.y)) {
      return false;
    }

    const auto dividers = tab->layout.dividers();
    const auto divider = std::ranges::find_if(dividers, [&](const auto& entry) {
      return entry.node_index == drag.node;
    });
    if (divider == dividers.end()) {
      return false;
    }

    const auto& frame = geometry(session);
    const auto parent_bounds = frame.pixels(divider->parent_bounds);
    const auto divider_bounds = frame.pixels(divider->bounds);
    const bool horizontal = divider->axis == ClientLayoutAxis::horizontal;
    const auto extent = horizontal ? parent_bounds.width - divider_bounds.width : parent_bounds.height - divider_bounds.height;
    const auto offset = horizontal ? drag.x - static_cast<double>(parent_bounds.x) - (static_cast<double>(divider_bounds.width / 2)) : drag.y - static_cast<double>(parent_bounds.y) - (static_cast<double>(divider_bounds.height / 2));

    if (extent <= 0) {
      return false;
    }

    const auto ratio = static_cast<std::uint16_t>(std::clamp(offset / static_cast<double>(extent), 0.0, 1.0) * PaneLayout::ratio_maximum);
    const bool moved = tab->layout.setSplitRatio({.node_index = drag.node, .ratio = ratio});

    if (moved) {
      session.invalidateView();
    }

    if (drag.commit) {
      retainLayout(session);
    }

    return moved;
  }

  bool split(Session& session, ClientLayoutAxis axis) {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr) {
      return false;
    }

    const auto focused = tab->focused_pane;

    return requestSplit(session, focused, axis, {});
  }

  bool splitAt(Session& session, ClientLayoutAxis axis, std::string_view directory) {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr || !directory.starts_with('/')) {
      return false;
    }

    const auto focused = tab->focused_pane;

    return requestSplit(session, focused, axis, {.directory = directory});
  }

  bool splitExplorer(Session& session, const ExplorerLayout& layout) {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr || !session.speaks(ClientTag::create_explorer_pane)) {
      return false;
    }

    const auto focused = tab->focused_pane;

    return requestSplit(session, focused, ClientLayoutAxis::horizontal, {.explorer = &layout});
  }

  bool splitEditor(Session& session, ClientLayoutAxis axis, std::span<const std::string_view> files, EditorStart start) {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    if (tab == nullptr || !session.speaks(ClientTag::create_nvim_pane) || files.size() > max_nvim_files) {
      return false;
    }

    // Read before the session lends itself to the request.
    const auto focused = tab->focused_pane;

    return requestSplit(session, focused, axis, {.editor = true, .files = files, .line = start.line, .column = start.column});
  }

  TabCreationOutcome createEditorTab(Session& session, std::span<const std::string_view> files) {
    if (!session.speaks(ClientTag::create_nvim_pane) || files.size() > max_nvim_files) {
      return TabCreationOutcome::unavailable;
    }

    return requestTab(session, {}, {.editor = true, .files = files});
  }

  bool closing(const Session& session, std::uint64_t pane_id) noexcept {
    return std::ranges::any_of(session.link.requests(), [&](const auto& request) {
      return request.kind == RequestKind::close_pane && request.pane_id == pane_id;
    });
  }

  bool closePane(Session& session, std::uint64_t pane_id) {
    if (paneOperationPending(session)) {
      return false;
    }

    session.link.sendRegistered(RequestKind::close_pane, ClosePane{.request_id = 0, .pane_id = pane_id}, pane_id);

    return true;
  }

  void toggleFullscreen(Session& session) {
    if (auto* tab = activeTabMut(session.tabs, session.active_tab)) {
      ++session.view_version.panes;
      tab->fullscreen = !tab->fullscreen;
      Access::synchronizeAttachments(session);
      retainLayout(session);
    }
  }

  void retainLayout(Session& session) {
    const auto& active_tab = session.active_tab;
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

      layouts.atMut(count++) = {.location = tab.location, .focused_pane = tab.focused_pane, .fullscreen = tab.fullscreen, .workspace_active = tab.workspace_active, .nodes = tab.layout.nodes()};
      retained_nodes += tab.layout.nodes().size();
    };

    if (const auto* active = activeTab(session.tabs, session.active_tab)) {
      append(*active);
    }

    for (const auto& tab : session.tabs) {
      if (!sameTab(tab->location, *active_tab)) {
        append(*tab);
      }
    }

    const auto active_found = std::ranges::any_of(layouts.view().first(count), [&](const auto& layout) {
      return sameTab(layout.location, *active_tab);
    });
    if (active_found) {
      session.link.send(UpdateClientLayout{.sidebar_visible = session.configuration.sidebar_visible, .sidebar_width = Access::sidebarColumns(session), .workspace_list_collapsed = session.workspaceListCollapsed(), .active_tab = *active_tab, .tabs = {layouts.data(), count}});
    }
  }

  // ---- workspaces ---------------------------------------------------------------------------

  bool selectWorkspace(Session& session, WorkspaceLocation location) {
    const auto& workspaces = session.workspace_list;
    const auto& active_tab = session.active_tab;
    if (!session.ready() || workspaces.revision() == 0 || session.requestsPending() || location.kind != WorkspaceLocation::Kind::workspace || workspaces.indexOf(location.id) == workspaces.entries().size() || (active_tab && sameWorkspace(active_tab->workspace, location))) {
      return false;
    }

    const auto bookmark = feature::bookmark(session.workbench, location);
    const auto target = bookmark ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = *bookmark} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = location.id};

    Access::handoffWorkspace(session, target, location.id);

    return true;
  }

  void selectWorkspaceAt(Session& session, std::size_t index) {
    const auto projects = session.workspace_list.projects();
    if (index < projects.size()) {
      static_cast<void>(selectWorkspace(session, projects[index].location));
    }
  }

  void createWorkspace(Session& session, WorkspaceDraft draft) {
    auto launch = session.launch_defaults.launch();

    if (!draft.path.empty()) {
      launch.cwd = draft.path;
    } else if (const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab); pane != nullptr) {
      launch.cwd_source = pane->id;
    }

    session.link.sendOpeningRequest(RequestKind::create_workspace, CreateWorkspace{.size = feature::launchSize(session.workbench), .name = draft.name, .create_cwd = draft.create_directory, .launch = launch});
  }

  void renameWorkspace(Session& session, std::string_view name) {
    if (const auto location = session.active_tab) {
      session.link.send(RenameWorkspace{.request_id = session.link.nextRequest(), .workspace = location->workspace, .name = name});
    }
  }

  bool openWorktree(Session& session, std::uint64_t identity) {
    const auto* row = session.workspace_list.worktree(identity);
    if (!session.ready() || row == nullptr || !row->workspace) {
      return false;
    }

    const auto workspace = *row->workspace;

    return selectWorkspace(session, {.kind = WorkspaceLocation::Kind::workspace, .id = workspace});
  }

  bool leaveWorktree(Session& session) {
    const auto& active_tab = session.active_tab;
    if (!session.ready() || !active_tab || active_tab->workspace.kind != WorkspaceLocation::Kind::workspace) {
      return false;
    }

    const auto* row = session.workspace_list.worktreeOfWorkspace(active_tab->workspace.id);
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

    for (const auto& row : session.workspace_list.worktrees()) {
      if (row.state != WorktreeState::gone || row.workspace) {
        continue;
      }

      if (session.link.requests().size() == Session::maximum_pending) {
        break;
      }

      session.link.sendRegistered(RequestKind::forget_worktree, ForgetWorktree{.request_id = 0, .worktree = row.id});

      ++sent;
    }

    return sent;
  }

  // ---- what the session and the other use cases hand the workbench --------------------------

  void visit(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> generation) {
    if (!session.ready() || !session.presented()) {
      return;
    }

    const auto* pane = findPane(session.panes, pane_id);
    const auto& active_tab = session.active_tab;
    if (pane != nullptr && (!generation || pane->generation == *generation) && active_tab && sameWorkspace(pane->location.workspace, active_tab->workspace)) {
      focusPane(session, pane_id);
    } else if (!session.requestsPending()) {
      Access::handoffPane(session, pane_id, features::activity::workspaceOf(session.agents(), session.paneList(), pane_id, generation));
    }
  }

  void launchTab(Session& session, std::span<const std::string_view> arguments) {
    if (activeTab(session.tabs, session.active_tab) != nullptr) {
      static_cast<void>(requestTab(session, {}, {.arguments = arguments}));
    } else {
      auto launch = session.launch_defaults.launch();

      launch.arguments = arguments;
      session.link.sendOpeningRequest(RequestKind::open_default, OpenPane{.size = feature::launchSize(session.workbench), .launch = launch});
    }
  }

  void launchSplit(Session& session, std::uint64_t pane_id, std::span<const std::string_view> arguments) {
    if (!requestSplit(session, pane_id, ClientLayoutAxis::horizontal, {.arguments = arguments})) {
      throw std::runtime_error{"PaneSplitUnavailable"};
    }
  }

  void setFocus(Session& session, TabLocation location, std::uint64_t pane_id) {
    if (auto* tab = feature::findMut(session.tabs.viewMut(), location); tab != nullptr && tab->focused_pane != pane_id) {
      tab->focused_pane = pane_id;
      ++session.view_version.panes;
    }

    terminal::graphics::focus(session, pane_id);
  }

  void resizeVisible(Session& session) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
    if (tab == nullptr) {
      return;
    }

    feature::arrange(session.workbench, *tab, [&panes = session.panes, &link = session.link, &view_version = session.view_version](std::uint64_t pane_id, TerminalSize size) {
      Session::resizePane(panes, link, view_version, pane_id, size);
    });
  }

  void recoverSplit(Session& session, TabLocation location, std::uint64_t pane_id) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
    const auto* pane = findPane(session.panes, pane_id);
    if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(tab->location, location) || !sameTab(pane->location, location)) {
      return;
    }

    feature::arrange(session.workbench, *tab, [&](std::uint64_t placed, TerminalSize size) {
      if (placed == pane_id) {
        session.link.send(PaneResize{.pane_id = pane_id, .size = size});
      }
    });
  }

  std::uint64_t neighbor(Session& session, PaneDirection direction) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
    if (tab == nullptr) {
      return 0;
    }

    return feature::neighbor(session.workbench, *tab, direction);
  }

  std::string_view exportLayout(Session& session) {
    const auto* tab = activeTabMut(session.tabs, session.active_tab);
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
        .sidebar_visible = session.configuration.sidebar_visible,
        .sidebar_width = Access::sidebarColumns(session),
        .workspace_list_collapsed = session.workspaceListCollapsed(),
        .active_tab = tab->location,
        .tabs = tabs,
    };

    return feature::LayoutToken::write(snapshot, Access::commandResponse(session));
  }

  void importLayout(Session& session, std::string_view token) {
    auto* tab = activeTabMut(session.tabs, session.active_tab);
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
    ++session.view_version.panes;
    tab->focused_pane = preset.focused_pane;
    tab->fullscreen = preset.fullscreen;
    Access::synchronizeAttachments(session);
    retainLayout(session);
  }

}
