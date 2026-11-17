module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.tbc;
import telar.gui.graphics.texture_cache;
import telar.gui.history.browser;
import telar.gui.input.copy_pointer;
import telar.gui.presentation.tab_drop;
import telar.gui.layout.snapshots;
import telar.gui.links.path_expansion;
import telar.gui.links.cell_links;
import telar.gui.features.paths;
import telar.gui.presentation.application_mark;
import telar.gui.features.palette;
import telar.config.client;
import telar.config.runtime;
import telar.gui.foundation.terminal;
import telar.gui.prompt.line;
import telar.base.text;
import telar.gui.prompt.layout;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.editor;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.memory.allocators;
import telar.gui.prompt.routing;
import telar.gui.prompt.editor;
import telar.shell.syntax;
import telar.gui.prompt.completion;

namespace telar::gui::application {

  template <typename Request, typename Fill>
  void Session::sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id, Fill&& fill) {
    request.request_id = pending(kind, pane_id);
    fill(pending_[pending_count_ - 1], std::as_const(request));
    try {
      send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  template <typename Request>
  void Session::sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id) {
    sendRegistered(kind, request, pane_id, [](Pending&, const Request&) {});
  }

  void Session::selectTab(TabLocation location) {
    if (!active_tab_ || !sameTab(*active_tab_, location)) {
      ++view_version_.active_tab;
      if (!active_tab_ || !sameWorkspace(active_tab_->workspace, location.workspace)) {
        ++view_version_.workspace;
      }
    }

    if (const auto* copy_pane = copyPane(); copy_pane != nullptr && !sameTab(copy_pane->location, location)) {
      copy_mode_.reset();
      copy_search_request_ = 0;
    }

    active_tab_ = location;
    auto& tab = ensureTab(location);

    for (const auto& candidate : tabs_) {
      if (sameWorkspace(candidate->location.workspace, location.workspace)) {
        candidate->workspace_active = candidate.get() == &tab;
      }
    }

    if (!tab.loaded && !tab.loading) {
      tab.loading = true;
      sendSnapshotRequest(RequestTabSnapshot{.location = location});
    }

    synchronizeAttachments();
    retainLayout();
  }

  bool Session::selectWorkspace(WorkspaceLocation location) {
    if (!ready_ || workspaces_.revision() == 0 || requestsPending() || location.kind != WorkspaceLocation::Kind::workspace || workspaces_.indexOf(location.id) == workspaces_.entries().size() || (active_tab_ && sameWorkspace(active_tab_->workspace, location))) {
      return false;
    }

    const auto* bookmark = navigation_history_.find(location);
    const auto target = bookmark != nullptr ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = bookmark->pane_id} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = location.id};

    handoffWorkspace(target, location.id);

    return true;
  }

  void Session::selectWorkspaceIndex(std::size_t index) {
    const auto projects = workspaces_.projects();
    if (index < projects.size()) {
      static_cast<void>(selectWorkspace(projects[index].location));
    }
  }

  void Session::focusPane(std::uint64_t pane_id) {
    auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      const auto agent = std::find_if(agents_.begin(), agents_.end(), [&](const auto& entry) {
        return entry.pane_id == pane_id;
      });
      if (agent == agents_.end()) {
        return;
      }

      // The agent's row is read before the pane table can grow.
      const auto location = agent->location;
      const auto generation = agent->pane_generation;

      pane = &ensurePane(pane_id, location);
      pane->generation = generation;
    }

    auto& tab = ensureTab(pane->location);

    setPaneFocus(tab, pane_id);
    selectTab(pane->location);
    synchronizeAttachments();
    retainLayout();
  }

  bool Session::openWorktree(std::uint64_t identity) {
    const auto* row = workspaces_.worktree(identity);
    if (!ready_ || row == nullptr || !row->workspace) {
      return false;
    }

    const auto workspace = *row->workspace;

    return selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = workspace});
  }

  bool Session::leaveWorktree() {
    if (!ready_ || !active_tab_ || active_tab_->workspace.kind != WorkspaceLocation::Kind::workspace) {
      return false;
    }

    const auto* row = workspaces_.worktreeOfWorkspace(active_tab_->workspace.id);
    if (row == nullptr) {
      return false;
    }

    const auto source = row->source;

    return selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = source});
  }

  std::size_t Session::forgetGoneWorktrees() {
    if (!ready_) {
      return 0;
    }

    std::size_t sent = 0;

    for (const auto& row : workspaces_.worktrees()) {
      if (row.state != WorktreeState::gone || row.workspace) {
        continue;
      }

      if (pending_count_ == pending_.size()) {
        break;
      }

      sendRegistered(RequestKind::forget_worktree, ForgetWorktree{.request_id = 0, .worktree = row.id});

      ++sent;
    }

    return sent;
  }

  TabCreationOutcome Session::createTab(std::string_view label) {
    return requestTabCreation(label, {});
  }

  TabCreationOutcome Session::createCommandTab(const runtime::config::CommandTabView& command) {
    if (command.count == 0 || command.count > command.arguments.size()) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    return requestTabCreation(command.label(), command.argv());
  }

  void Session::createWorkspace(WorkspaceDraft draft) {
    auto launch = defaultLaunch();

    if (!draft.path.empty()) {
      launch.cwd = draft.path;
    } else if (const auto* pane = focusedPane(); pane != nullptr) {
      launch.cwd_source = pane->id;
    }

    sendOpeningRequest(RequestKind::create_workspace, CreateWorkspace{.size = launchSize(), .name = draft.name, .create_cwd = draft.create_directory, .launch = launch});
  }

  std::optional<std::string_view> Session::fileBase(const FilePath& path, std::string_view executable, std::optional<std::uint64_t> source_id) const {
    if (executable.empty()) {
      throw std::runtime_error{"EditorUnavailable"};
    }

    if (!source_id) {
      if (!path.text().starts_with('/')) {
        throw std::invalid_argument{"RelativeFileLink"};
      }

      return std::nullopt;
    }

    const auto* source = findPane(*source_id);
    if (source == nullptr || !active_tab_ || !sameTab(source->location, *active_tab_)) {
      throw std::runtime_error{"PaneNotFound"};
    }

    if (path.text().starts_with('/')) {
      return std::nullopt;
    }

    return std::string_view{source->cwd};
  }

  void Session::openAnchoredFile(const FilePath& path, std::string_view executable, std::string_view anchored, std::optional<std::uint64_t> source_id) {
    if (!source_id) {
      createEditorTab(EditorTarget{executable, path.text(), path.line(), path.column()});

      return;
    }

    const auto* source = findPane(*source_id);
    const EditorRequest request{
        .request_id = source->generation == 0 ? 0 : nextRequest(),
        .source = {.pane_id = source->id, .pane_generation = source->generation, .attachment_generation = source->attachment_generation, .location = source->location},
        .target = EditorTarget{executable, path.text().starts_with('/') ? path.text() : anchored, path.line(), path.column()},
    };

    if (source->generation == 0) {
      splitEditorPane(request);

      return;
    }

    editor_opening_.begin(request);
    try {
      send(request.message());
    } catch (...) {
      static_cast<void>(editor_opening_.complete(request.request_id));
      throw;
    }
  }

  void Session::setWorkbenchGeometry(WorkbenchGeometry geometry) noexcept {
    if (workbench_geometry_ != geometry) {
      workbench_geometry_ = geometry;
      ++view_version_.viewport;
    }
  }

  void Session::setAttachmentReservation(std::optional<PaneBottomReservation> reservation) {
    if (attachment_reservation_ != reservation) {
      attachment_reservation_ = reservation;
      attachment_resize_pending_ = true;
      for (auto& tab : tabs_) {
        tab->layout.setBottomReservation(reservation);
      }

      ++view_version_.viewport;
    }

    if (attachment_resize_pending_) {
      if (auto* tab = activeTab()) {
        resizeVisiblePanes(*tab);
      }

      attachment_resize_pending_ = false;
    }
  }

  const WorkbenchGeometry& Session::workbenchGeometry() const noexcept {
    return workbench_geometry_;
  }

  bool Session::split(ClientLayoutAxis axis) {
    const auto* tab = activeTab();
    if (tab == nullptr) {
      return false;
    }

    return requestPaneSplit(tab->focused_pane, axis, defaultLaunch());
  }

  bool Session::closePane(std::uint64_t pane_id) {
    if (hasPaneOperation()) {
      return false;
    }

    sendRegistered(RequestKind::close_pane, ClosePane{0, pane_id}, pane_id);

    return true;
  }

  void Session::closeTab(TabLocation location) {
    if (!hasTabOperation()) {
      sendTabOperation(RequestKind::close_tab, CloseTab{.location = location});
    }
  }

  void Session::renameTab(std::string_view label) {
    if (const auto location = active_tab_; location && !hasTabOperation()) {
      sendTabOperation(RequestKind::rename_tab, RenameTab{.location = *location, .label = label});
    }
  }

  void Session::selectTabIndex(std::size_t index) {
    std::array<Tab<Memory>*, maximum_tabs> ordered{};
    const auto count = orderedTabs(ordered);
    if (index < count) {
      selectTab(ordered[index]->location);
    }
  }

  void Session::selectTabOffset(std::int32_t offset) {
    std::array<Tab<Memory>*, maximum_tabs> ordered{};
    const auto count = orderedTabs(ordered);
    const auto active = std::find(ordered.begin(), ordered.begin() + count, activeTab());
    if (count == 0 || active == ordered.begin() + count) {
      return;
    }

    const auto index = static_cast<std::int64_t>(active - ordered.begin());
    const auto size = static_cast<std::int64_t>(count);
    const auto next = (((index + offset) % size) + size) % size;

    selectTab(ordered[static_cast<std::size_t>(next)]->location);
  }

  void Session::moveTab(TabMoveDirection direction, std::optional<std::uint64_t> relative_to) {
    if (const auto location = active_tab_) {
      static_cast<void>(requestTabMove({.location = *location, .direction = direction, .relative_to = relative_to}));
    }
  }

  bool Session::tabOperationPending() const noexcept {
    return hasTabOperation();
  }

  bool Session::requestTabMove(const TabDragMove& move) {
    if (hasTabOperation() || !active_tab_ || !sameWorkspace(active_tab_->workspace, move.location.workspace) || findTab(move.location) == nullptr) {
      return false;
    }

    if (move.relative_to && (*move.relative_to == move.location.tab_id || findTab({.workspace = move.location.workspace, .tab_id = *move.relative_to}) == nullptr)) {
      return false;
    }

    sendTabOperation(RequestKind::move_tab, MoveTab{.location = move.location, .direction = move.direction, .relative_to = move.relative_to});

    return true;
  }

  void Session::focusDirection(PaneDirection direction) {
    if (const auto neighbor = neighboringPane(direction); neighbor != 0) {
      focusPane(neighbor);
    }
  }

  void Session::navigateDirection(PaneDirection direction) {
    const auto* pane = focusedPane();
    if (pane == nullptr || pane->foreground != "nvim") {
      focusDirection(direction);

      return;
    }

    constexpr auto characters = std::to_array<std::pair<PaneDirection, char>>({
        {PaneDirection::left, 'h'},
        {PaneDirection::right, 'l'},
        {PaneDirection::up, 'k'},
        {PaneDirection::down, 'j'},
    });

    const auto* const found = std::ranges::find(characters, direction, &decltype(characters)::value_type::first);
    if (found == characters.end()) {
      return;
    }

    const TerminalKey key{.codepoint = static_cast<std::uint32_t>(found->second), .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
    KeyEncoder encoder;

    input(pane->id, encoder.encode(key, pane->screen.modes()));
  }

  bool Session::resizeDirection(PaneDirection direction) {
    auto* tab = activeTab();
    if (tab == nullptr || tab->fullscreen || !tab->layout.resize(tab->focused_pane, direction, workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics)) {
      return false;
    }

    ++view_version_.panes;
    retainLayout();

    return true;
  }

  void Session::renameWorkspace(std::string_view name) {
    if (const auto location = active_tab_) {
      send(RenameWorkspace{nextRequest(), location->workspace, name});
    }
  }

  void Session::toggleFullscreen() {
    if (auto* tab = activeTab()) {
      ++view_version_.panes;
      tab->fullscreen = !tab->fullscreen;
      synchronizeAttachments();
      retainLayout();
    }
  }

  void Session::retainLayout() {
    if (!ready_ || !active_tab_) {
      return;
    }

    std::array<ClientTabLayout, maximum_tabs> layouts;
    std::size_t count = 0;
    std::size_t retained_nodes = 0;
    const auto append = [&](const Tab<Memory>& tab) {
      if (!tab.loaded || tab.layout.nodes().empty() || tab.focused_pane == 0 || retained_nodes + tab.layout.nodes().size() > maximum_retained_layout_nodes) {
        return;
      }

      layouts[count++] = {tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, tab.layout.nodes()};
      retained_nodes += tab.layout.nodes().size();
    };

    if (const auto* active = activeTab()) {
      append(*active);
    }

    for (const auto& tab : tabs_) {
      if (!sameTab(tab->location, *active_tab_)) {
        append(*tab);
      }
    }

    const auto active_found = std::any_of(layouts.begin(), layouts.begin() + count, [&](const auto& layout) {
      return sameTab(layout.location, *active_tab_);
    });
    if (active_found) {
      send(UpdateClientLayout{.sidebar_visible = configuration_.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .active_tab = *active_tab_, .tabs = {layouts.data(), count}});
    }
  }

  WindowTitle Session::windowTitle(std::string_view hostname) const {
    const auto* tab = activeTab();
    const auto* pane = focusedPane();
    WindowTitle::Tokens tokens{.workspace = {}, .tab = {}, .pane_title = pane != nullptr ? std::string_view{pane->title} : std::string_view{}, .hostname = hostname};

    if (tab != nullptr) {
      if (!tab->label.empty()) {
        tokens.tab = tab->label;
      } else {
        tokens.tab = tabApplicationName(*tab, pane);
      }

      const auto workspace = std::ranges::find_if(workspaces_, [&](const auto& entry) {
        return sameWorkspace(entry.location, tab->location.workspace);
      });
      if (workspace != workspaces_.end()) {
        tokens.workspace = workspace->name;
      }
    }

    const auto pattern = configuration_.window_title.view();

    return WindowTitle::render(pattern.empty() ? WindowTitle::default_title : pattern, tokens);
  }

  TerminalSize Session::launchSize() const {
    const auto size = workbench_geometry_.launchSize();
    if (!size) {
      throw std::runtime_error{"TerminalTooSmall"};
    }

    return *size;
  }

  template <typename Request>
    requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
  void Session::sendOpeningRequest(RequestKind kind, Request request, TabLocation location, std::optional<std::uint64_t> fallback_workspace) {
    sendRegistered(kind, request, 0, [&](Pending& registered, const Request& sent) {
      registered.size = sent.size;
      registered.location = location;
      registered.fallback_workspace = fallback_workspace;
      if constexpr (std::same_as<Request, OpenPane>) {
        registered.pane_id = sent.target.kind == PaneTarget::Kind::pane ? sent.target.id : 0;
      }
    });
  }

  template <typename Request>
    requires(std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot>)
  void Session::sendSnapshotRequest(Request request) {
    constexpr auto kind = std::same_as<Request, RequestTabSnapshot> ? RequestKind::tab_snapshot : RequestKind::workspace_snapshot;

    sendRegistered(kind, request, 0, [](Pending& registered, const Request& sent) {
      if constexpr (std::same_as<Request, RequestTabSnapshot>) {
        registered.location = sent.location;
      } else {
        registered.location.workspace = sent.workspace;
      }
    });
  }

  bool Session::completeRequest(RequestKind kind, std::uint64_t request_id) noexcept {
    const auto requests = std::span{pending_}.first(pending_count_);
    const auto found = std::ranges::find_if(requests, [&](const Pending& request) {
      return request.id == request_id && request.kind == kind;
    });
    if (found == requests.end()) {
      return false;
    }

    complete(request_id);

    return true;
  }

  bool Session::hasPaneOperation() const noexcept {
    return std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const auto& request) {
      return request.kind == RequestKind::split || request.kind == RequestKind::close_pane;
    });
  }

  auto Session::splitSizes(Tab<Memory>& tab, std::uint64_t pane_id, ClientLayoutAxis axis) noexcept -> std::optional<SplitSizes> {
    const auto fullscreen = tab.fullscreen ? std::optional{tab.focused_pane} : std::nullopt;
    const auto bounds = tab.layout.prospectiveSplit(workbench_geometry_.cellArea(), axis, pane_id, workbench_geometry_.layout_metrics, fullscreen);
    if (!bounds) {
      return std::nullopt;
    }

    const auto existing = workbench_geometry_.contentSize(bounds->existing_content);
    const auto added = workbench_geometry_.contentSize(bounds->added_content);
    if (!existing || !added) {
      return std::nullopt;
    }

    return SplitSizes{.existing = *existing, .added = *added};
  }

  bool Session::requestPaneSplit(std::uint64_t pane_id, ClientLayoutAxis axis, Launch launch) {
    auto* tab = activeTab();
    const auto* pane = findPane(pane_id);
    if (hasPaneOperation() || tab == nullptr || pane == nullptr || !pane->attached || pane->exited || !sameTab(pane->location, tab->location)) {
      return false;
    }

    const auto sizes = splitSizes(*tab, pane_id, axis);
    if (!sizes) {
      return false;
    }

    const auto request_id = pending(RequestKind::split, pane_id, axis);
    auto& registration = pending_[pending_count_ - 1];

    registration.location = tab->location;
    registration.size = sizes->added;
    const auto registered = registration;

    launch.cwd_source = pane_id;
    try {
      send(PaneResize{.pane_id = pane_id, .size = sizes->existing});
      send(CreatePane{.request_id = request_id, .location = tab->location, .size = sizes->added, .launch = launch});
    } catch (...) {
      complete(request_id);
      recoverSplit(registered);
      throw;
    }

    return true;
  }

  void Session::recoverSplit(const Pending& request) {
    auto* tab = activeTab();
    const auto* pane = findPane(request.pane_id);
    if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(tab->location, request.location) || !sameTab(pane->location, request.location)) {
      return;
    }

    const auto fullscreen = tab->fullscreen ? std::optional{tab->focused_pane} : std::nullopt;
    const auto placements = tab->layout.arrange(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, fullscreen);
    const auto target = std::ranges::find(placements, request.pane_id, &PaneLayout::Placement::pane_id);
    if (target != placements.end()) {
      if (const auto size = workbench_geometry_.contentSize(target->content)) {
        send(PaneResize{.pane_id = request.pane_id, .size = *size});
      }
    }
  }

  void Session::resizeVisiblePanes(Tab<Memory>& tab) {
    const auto fullscreen = tab.fullscreen ? std::optional{tab.focused_pane} : std::nullopt;
    const auto placements = tab.layout.arrange(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, fullscreen);

    for (const auto& placement : placements) {
      if (const auto size = workbench_geometry_.contentSize(placement.content)) {
        resize(placement.pane_id, *size);
      }
    }
  }

  Pane<Memory>& Session::allocateSplitPane(const Pending& request, const PaneOpened& message) {
    try {
      return ensurePane(message.pane_id, message.location);
    } catch (...) {
      recoverSplit(request);
      send(DetachPane{message.pane_id});
      throw;
    }
  }

  Change Session::adoptSplit(const Pending& request, const PaneOpened& message) {
    if (!message.created || message.pane_id == 0 || message.pane_id == request.pane_id || !sameTab(message.location, request.location)) {
      throw EncodingError{"UnexpectedPaneSplit"};
    }

    auto* tab = findTab(request.location);
    if (tab == nullptr) {
      if (findPane(message.pane_id) == nullptr) {
        send(DetachPane{message.pane_id});
      }

      return Change::none;
    }

    if (!tab->layout.contains(message.pane_id) && tab->layout.nodes().size() + 2 > PaneLayout::maximum_nodes) {
      throw EncodingError{"Pane layout exceeds capacity"};
    }

    const auto* known = findPane(message.pane_id);
    if (known != nullptr && !sameTab(known->location, request.location)) {
      throw EncodingError{"Pane already belongs to another tab"};
    }

    auto& pane = allocateSplitPane(request, message);

    pane.generation = message.pane_generation;
    pane.size = request.size;
    pane.attaching = false;
    const auto beside = tab->layout.contains(request.pane_id) ? request.pane_id : tab->layout.firstPane();

    if (!tab->layout.contains(pane.id)) {
      tab->layout.add(pane.id, request.axis, beside);
    }

    if (active_tab_ && sameTab(*active_tab_, tab->location)) {
      confirmAttachment(pane);
      setPaneFocus(*tab, pane.id);
      resizeVisiblePanes(*tab);
    } else {
      send(DetachPane{pane.id});
    }

    ++view_version_.panes;
    synchronizeAttachments();
    retainLayout();

    if (message.pane_generation == 0) {
      sendSnapshotRequest(RequestTabSnapshot{.location = message.location});
    }

    return Change::model;
  }

  bool Session::hasTabOperation() const noexcept {
    return std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const auto& request) {
      return request.kind == RequestKind::create_tab || request.kind == RequestKind::rename_tab || request.kind == RequestKind::move_tab || request.kind == RequestKind::close_tab;
    });
  }

  template <typename Request>
  void Session::sendTabOperation(RequestKind kind, Request request) {
    sendRegistered(kind, request, 0, [](Pending& registered, const Request& sent) {
      if constexpr (std::same_as<Request, CreateTab>) {
        registered.location.workspace = sent.workspace;
        registered.size = sent.size;
      } else {
        registered.location = sent.location;
      }
    });
  }

  template <typename Value>
  void Session::reserveAppend(Vector<Value, Memory>& values, std::size_t maximum) {
    if (values.size() < values.capacity()) {
      return;
    }

    constexpr std::size_t growth_factor = 2;
    const auto grown = values.capacity() > maximum / growth_factor ? maximum : values.capacity() * growth_factor;

    values.reserve(std::max(values.size() + 1, grown));
  }

  TabCreationOutcome Session::requestTabCreation(std::string_view label, std::span<const std::string_view> arguments) {
    if (hasTabOperation()) {
      return TabCreationOutcome::busy;
    }

    constexpr std::size_t maximum_label_bytes = 128;

    DisplayText16<maximum_label_bytes>::validate(label);
    const auto* tab = activeTab();
    const auto* pane = focusedPane();
    if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(pane->location, tab->location)) {
      return TabCreationOutcome::unavailable;
    }

    auto launch = defaultLaunch();

    launch.cwd_source = pane->id;
    if (!arguments.empty()) {
      launch.arguments = arguments;
    }

    sendTabOperation(RequestKind::create_tab, CreateTab{.workspace = tab->location.workspace, .label = label, .size = launchSize(), .launch = launch});

    return TabCreationOutcome::requested;
  }

  Tab<Memory>* Session::findTab(TabLocation location) const noexcept {
    const auto found = std::find_if(tabs_.begin(), tabs_.end(), [&](const auto& tab) {
      return sameTab(tab->location, location);
    });

    return found == tabs_.end() ? nullptr : found->get();
  }

  Tab<Memory>& Session::ensureTab(TabLocation location) {
    if (auto* tab = findTab(location)) {
      return *tab;
    }

    if (tabs_.size() == maximum_tabs) {
      throw std::length_error{"GUI tab capacity reached"};
    }

    tabs_.push_back(makeOwned<Tab<Memory>>(memory_, memory_, location));
    tabs_.back()->layout.setBottomReservation(attachment_reservation_);
    ++view_version_.tabs;

    return *tabs_.back();
  }

  Pane<Memory>& Session::ensurePane(std::uint64_t pane_id, TabLocation location) {
    if (auto* pane = findPane(pane_id)) {
      return *pane;
    }

    if (panes_.size() == maximum_panes) {
      throw std::length_error{"GUI pane capacity reached"};
    }

    panes_.push_back(makeOwned<Pane<Memory>>(memory_, memory_, pane_id, graphics_budget_));
    panes_.back()->location = location;
    ++view_version_.panes;

    return *panes_.back();
  }

  void Session::setPaneFocus(Tab<Memory>& tab, std::uint64_t pane_id) {
    if (tab.focused_pane != pane_id) {
      tab.focused_pane = pane_id;
      ++view_version_.panes;
    }

    graphics_pauses_.focus({.pane_id = pane_id, .now_ns = now_()}, [this](std::uint64_t paused_pane) {
      requestGraphicsSnapshot(paused_pane);
    });
  }

  void Session::openDefault() {
    if (!presented_) {
      initial_open_pending_ = true;
      deferred_tab_.reset();

      return;
    }

    const auto launch = defaultLaunch();

    sendOpeningRequest(RequestKind::open_default, OpenPane{.size = launchSize(), .launch = launch});
  }

  auto Session::machineBookmark() const noexcept -> std::optional<MachineBookmark> {
    const auto* tab = activeTab();
    if (tab == nullptr) {
      return std::nullopt;
    }

    std::optional<std::uint64_t> fallback;

    if (tab->location.workspace.kind == WorkspaceLocation::Kind::workspace) {
      fallback = tab->location.workspace.id;
    } else if (const auto* row = workspaces_.worktree(tab->location.workspace.id)) {
      fallback = row->source;
    }

    return MachineBookmark{.location = tab->location, .pane_id = tab->focused_pane, .fallback_workspace = fallback};
  }

  bool Session::recoverMissingWorkspacePane(const Pending& request, const RequestFailed& failure) {
    if ((request.kind != RequestKind::restore_machine && request.kind != RequestKind::visit_pane) || !request.fallback_workspace || failure.code != FailureCode::pane_not_found) {
      return false;
    }

    navigation_history_.forget({.kind = WorkspaceLocation::Kind::workspace, .id = *request.fallback_workspace});
    sendOpeningRequest(RequestKind::open_default, OpenPane{.target = {.kind = PaneTarget::Kind::workspace, .id = *request.fallback_workspace}, .size = launchSize()});

    return true;
  }

  void Session::handoffPane(std::uint64_t pane_id, std::optional<std::uint64_t> fallback_workspace) {
    handoffWorkspace({.kind = PaneTarget::Kind::pane, .id = pane_id}, fallback_workspace);
  }

  void Session::handoffWorkspace(PaneTarget target, std::optional<std::uint64_t> fallback_workspace) {
    const OpenPane opening{.target = target, .size = launchSize()};

    try {
      retainLayout();
      for (auto& pane : panes_) {
        if (pane->attached || pane->attaching) {
          prepareDetach(pane->id);
          send(DetachPane{pane->id});
          pane->attached = false;
          pane->attaching = false;
        }
      }

      sendOpeningRequest(RequestKind::visit_pane, opening, {}, fallback_workspace);
    } catch (...) {
      const auto failure = std::current_exception();

      try {
        synchronizeAttachments();
      } catch (...) {
        std::rethrow_exception(failure);
      }

      throw;
    }

    releaseWorkspacePresentation();
  }

  void Session::releaseWorkspacePresentation() noexcept {
    const auto* tab = activeTab();
    if (tab != nullptr && findPane(tab->focused_pane) != nullptr) {
      navigation_history_.remember({.location = tab->location, .pane_id = tab->focused_pane, .layout = NavigationHistory::Layout{tab->layout, tab->focused_pane}, .fullscreen = tab->fullscreen});
    }

    for (const auto& known : tabs_) {
      if (known->loaded && known->focused_pane != 0) {
        saved_layouts_.retain({.location = known->location, .pane_id = known->focused_pane, .focused_pane = known->focused_pane, .workspace_active = active_tab_ && sameTab(*active_tab_, known->location), .fullscreen = known->fullscreen, .nodes = known->layout.nodes()});
      }
    }

    panes_.clear();
    tabs_.clear();
    active_tab_.reset();
    pending_layout_restore_.reset();
    copy_mode_.reset();
    copy_search_request_ = 0;
    history_.suspend();
    features::paths::close(paths_);
    features::palette::discard(palette_);
    graphics_pauses_.reset();
    editor_opening_.reset();
    ++view_version_.workspace;
    ++view_version_.tabs;
    ++view_version_.active_tab;
    ++view_version_.panes;
    ++view_version_.host;
  }

  void Session::restoreMachinePresentation() {
    if (active_tab_) {
      synchronizeAttachments();

      return;
    }

    if (std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const Pending& request) {
          return request.kind == RequestKind::open_default || request.kind == RequestKind::restore_machine || request.kind == RequestKind::create_workspace;
        })) {
      return;
    }

    if (initial_open_pending_) {
      if (deferred_tab_) {
        const auto location = *deferred_tab_;

        openRestoredWorkspace(location);
      } else {
        openDefault();
      }

      initial_open_pending_ = false;
      deferred_tab_.reset();
      left_machine_.reset();

      return;
    }

    if (left_machine_) {
      const auto bookmark = *left_machine_;
      const auto target = bookmark.pane_id != 0 ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = bookmark.pane_id} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = bookmark.fallback_workspace.value_or(bookmark.location.workspace.id)};

      sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = target, .size = launchSize()}, bookmark.location, bookmark.fallback_workspace);
    }
  }

  void Session::openRestoredWorkspace(TabLocation location) {
    const auto saved = saved_layouts_.find(location);
    if (!saved) {
      throw EncodingError{"InvalidClientLayoutActiveTab"};
    }

    const auto fallback = location.workspace.kind == WorkspaceLocation::Kind::workspace ? std::optional{location.workspace.id} : std::nullopt;

    sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = {.kind = PaneTarget::Kind::pane, .id = saved->pane_id}, .size = launchSize()}, location, fallback);
  }

  void Session::stageWorkspaceLayout(Tab<Memory>& tab) {
    pending_layout_restore_.reset();
    if (const auto saved = saved_layouts_.find(tab.location)) {
      pending_layout_restore_ = {.location = saved->location, .pane_id = saved->focused_pane, .layout = NavigationHistory::Layout{saved->nodes, saved->focused_pane}, .fullscreen = saved->fullscreen};
    } else if (const auto* bookmark = navigation_history_.find(tab.location.workspace); bookmark != nullptr && sameTab(bookmark->location, tab.location)) {
      pending_layout_restore_ = *bookmark;
    }

    tab.layout.restore({});
    tab.focused_pane = 0;
    tab.fullscreen = false;
    tab.loaded = false;
    tab.loading = false;
  }

  void Session::restoreCanonicalLayout(Tab<Memory>& tab) {
    if (pending_layout_restore_ && sameTab(pending_layout_restore_->location, tab.location)) {
      if (pending_layout_restore_->layout) {
        tab.layout.restore(pending_layout_restore_->layout->view());
        tab.fullscreen = pending_layout_restore_->fullscreen;
        setPaneFocus(tab, pending_layout_restore_->layout->focused_pane);
      }

      pending_layout_restore_.reset();
    } else if (const auto saved = saved_layouts_.find(tab.location)) {
      tab.layout.restore(saved->nodes);
      tab.fullscreen = saved->fullscreen;
      setPaneFocus(tab, saved->focused_pane);
    }

    saved_layouts_.forget(tab.location);
  }

  void Session::createEditorTab(const EditorTarget& target) {
    EditorLaunch command;
    auto launch = defaultLaunch();

    launch.arguments = command.arguments(target.editor(), target.path(), target.line(), target.column());
    if (activeTab() != nullptr) {
      static_cast<void>(requestTabCreation({}, launch.arguments));
    } else {
      sendOpeningRequest(RequestKind::open_default, OpenPane{.size = launchSize(), .launch = launch});
    }
  }

  void Session::splitEditorPane(const EditorRequest& request) {
    EditorLaunch command;
    auto launch = defaultLaunch();
    const auto& target = request.target;

    launch.arguments = command.arguments(target.editor(), target.path(), target.line(), target.column());
    if (!requestPaneSplit(request.source.pane_id, ClientLayoutAxis::horizontal, launch)) {
      throw std::runtime_error{"PaneSplitUnavailable"};
    }
  }

  void Session::confirmAttachment(Pane<Memory>& pane) {
    if (pane.attached) {
      return;
    }

    if (attachment_generation_ == std::numeric_limits<std::uint64_t>::max()) {
      throw std::overflow_error{"AttachmentGenerationExhausted"};
    }

    pane.attachment_generation = ++attachment_generation_;
    pane.attached = true;
    ++chrome_revision_;
  }

  Launch Session::defaultLaunch() const noexcept {
    static constexpr std::array<std::string_view, 1> default_shell{"/bin/sh"};
    const auto arguments = launch_argument_count_ == 0 ? std::span<const std::string_view>{default_shell} : std::span<const std::string_view>{launch_arguments_}.first(launch_argument_count_);

    return {.cwd = launch_cwd_.empty() ? std::string_view{"/"} : std::string_view{launch_cwd_}, .arguments = arguments};
  }

  void Session::synchronizeAttachments() {
    if (!presented_) {
      return;
    }

    acknowledgeFocusedAgent();
    const auto* active = activeTab();

    for (auto& pane : panes_) {
      const auto visible = active != nullptr && active->layout.contains(pane->id) && (!active->fullscreen || pane->id == active->focused_pane);
      if (visible && !pane->attached && !pane->attaching && !pane->exited) {
        pane->attaching = true;
        try {
          sendOpeningRequest(RequestKind::attach, OpenPane{.target = {PaneTarget::Kind::pane, pane->id}, .size = pane->size});
        } catch (...) {
          pane->attaching = false;
          throw;
        }
      } else if (!visible && pane->attached) {
        prepareDetach(pane->id);
        send(DetachPane{pane->id});
        pane->attached = false;
        pane->acknowledged_frame = 0;
        pane->screen.detach();
        pane->graphics.detach();
      }
    }
  }

  void Session::prepareDetach(std::uint64_t pane_id) {
    if (copy_mode_.state() && copy_mode_.state()->pane_id == pane_id) {
      copy_mode_.reset();
      copy_search_request_ = 0;
    }

    transport_.willDetach(pane_id);
  }

  Change Session::apply(const PaneOpened& message) {
    const auto request = complete(message.request_id);
    if (!request) {
      if (findPane(message.pane_id) == nullptr) {
        send(DetachPane{message.pane_id});
      }

      return Change::none;
    }

    if (request->kind == RequestKind::split) {
      return adoptSplit(*request, message);
    }

    if (request->kind == RequestKind::peek_diff) {
      if (presented_ && message.location.workspace.kind == WorkspaceLocation::Kind::workspace && !requestsPending()) {
        handoffPane(message.pane_id, message.location.workspace.id);
      }

      return Change::model;
    }

    const bool discovered = findPane(message.pane_id) != nullptr;
    auto& pane = ensurePane(message.pane_id, message.location);
    if (pane.generation != message.pane_generation) {
      ++view_version_.panes;
    }

    const auto desired_size = discovered ? pane.size : request->size;

    pane.size = request->size;

    pane.generation = message.pane_generation;
    pane.location = message.location;
    confirmAttachment(pane);
    pane.attaching = false;
    pane.exited = false;
    auto& tab = ensureTab(message.location);

    if (request->kind != RequestKind::attach) {
      stageWorkspaceLayout(tab);
    }

    const auto axis = request ? request->axis : ClientLayoutAxis::horizontal;
    const auto beside = request && request->kind == RequestKind::split ? request->pane_id : tab.focused_pane;

    tab.layout.add(pane.id, axis, beside);

    if (!tab.loading && !tab.loaded) {
      tab.loading = true;
      sendSnapshotRequest(RequestTabSnapshot{.location = tab.location});
      sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = tab.location.workspace});
    }

    if (request->kind != RequestKind::attach) {
      setPaneFocus(tab, pane.id);
      selectTab(message.location);
      left_machine_.reset();
    }

    synchronizeAttachments();
    resize(pane.id, desired_size);
    retainLayout();

    return Change::model;
  }

  Change Session::apply(const TabCreated& message) {
    const auto request = complete(message.request_id);
    const auto* previous = activeTab();
    if (!request || request->kind != RequestKind::create_tab || !sameWorkspace(request->location.workspace, message.location.workspace) || previous == nullptr || !sameWorkspace(previous->location.workspace, message.location.workspace)) {
      throw EncodingError{"UnexpectedTabCreated"};
    }

    const auto cached = std::ranges::find_if(tabs_, [&](const auto& tab) {
      return sameTab(tab->location, message.location);
    });

    const bool discovered = cached != tabs_.end();
    if ((discovered && ((*cached)->loaded || (*cached)->loading || !(*cached)->layout.nodes().empty())) || findPane(message.root_pane_id) != nullptr) {
      throw EncodingError{"Tab or pane already exists"};
    }

    const auto cached_index = static_cast<std::size_t>(cached - tabs_.begin());
    const auto count = static_cast<std::size_t>(std::ranges::count_if(tabs_, [&](const auto& tab) {
      return sameWorkspace(tab->location.workspace, message.location.workspace);
    })) - static_cast<std::size_t>(discovered);
    if (count >= maximum_workspace_tabs || message.position > count || (!discovered && tabs_.size() == maximum_tabs) || panes_.size() == maximum_panes) {
      throw EncodingError{"Invalid tab position or capacity"};
    }

    auto tab = makeOwned<Tab<Memory>>(memory_, memory_, message.location);

    tab->label = message.label;
    tab->position = message.position;
    if (discovered) {
      tab->foreground = (*cached)->foreground;
      tab->foreground_pane = (*cached)->foreground_pane;
    }

    tab->layout.add(message.root_pane_id, ClientLayoutAxis::horizontal, tab->focused_pane);
    tab->focused_pane = message.root_pane_id;
    tab->loaded = true;
    auto pane = makeOwned<Pane<Memory>>(memory_, memory_, message.root_pane_id, graphics_budget_);

    pane->generation = message.pane_generation;
    pane->location = message.location;
    pane->size = request->size;
    if (!discovered) {
      reserveAppend(tabs_, maximum_tabs);
    }

    reserveAppend(panes_, maximum_panes);
    confirmAttachment(*pane);

    if (discovered) {
      tabs_[cached_index] = std::move(tab);
    } else {
      for (auto& existing : tabs_) {
        if (sameWorkspace(existing->location.workspace, message.location.workspace) && existing->position >= message.position) {
          ++existing->position;
        }
      }

      tab->layout.setBottomReservation(attachment_reservation_);
      tabs_.push_back(std::move(tab));
    }

    panes_.push_back(std::move(pane));
    ++view_version_.tabs;
    ++view_version_.panes;
    selectTab(message.location);
    synchronizeAttachments();
    retainLayout();

    return Change::model;
  }

  Change Session::apply(const TabSnapshot& message) {
    completeRequest(RequestKind::tab_snapshot, message.request_id);
    if (!presented_ && !leave_pending_) {
      return Change::none;
    }

    auto& tab = ensureTab(message.location);

    restoreCanonicalLayout(tab);
    tab.loaded = true;
    tab.loading = false;
    ++chrome_revision_;
    std::array<std::uint64_t, PaneLayout::maximum_panes> removed{};
    std::size_t removed_count = 0;

    for (const auto& node : tab.layout.nodes()) {
      const auto* leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf != nullptr && std::none_of(message.panes.begin(), message.panes.end(), [&](const auto& pane) {
            return pane.pane_id == leaf->pane_id;
          })) {
        removed[removed_count++] = leaf->pane_id;
      }
    }

    for (const auto identity : std::span{removed}.first(removed_count)) {
      tab.layout.remove(identity);
      ++view_version_.panes;
    }

    for (const auto& descriptor : message.panes) {
      auto& pane = ensurePane(descriptor.pane_id, message.location);
      if (pane.generation != descriptor.pane_generation || pane.exited != (descriptor.lifecycle == PaneLifecycle::exited)) {
        ++view_version_.panes;
      }

      pane.generation = descriptor.pane_generation;
      pane.exited = descriptor.lifecycle == PaneLifecycle::exited;
      tab.layout.add(pane.id, ClientLayoutAxis::horizontal, tab.layout.firstPane());
    }

    if (!tab.layout.contains(tab.focused_pane)) {
      setPaneFocus(tab, tab.layout.firstPane());
    }

    synchronizeAttachments();
    retainLayout();
    removePanes([&](const Pane<Memory>& pane) {
      return sameTab(pane.location, message.location) && !tab.layout.contains(pane.id);
    });

    return Change::model;
  }

  Change Session::apply(const WorkspaceSnapshot& message) {
    const bool current_workspace = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);

    completeRequest(RequestKind::workspace_snapshot, message.request_id);
    std::array<TabLocation, maximum_tabs> removed;
    std::size_t removed_count = 0;

    for (const auto& tab : tabs_) {
      if (sameWorkspace(tab->location.workspace, message.workspace) && std::none_of(message.tabs.begin(), message.tabs.end(), [&](const auto& entry) {
            return entry.tab_id == tab->location.tab_id;
          })) {
        removed[removed_count++] = tab->location;
      }
    }

    for (const auto& location : std::span{removed}.first(removed_count)) {
      discardTab(location);
    }

    for (auto& workspace : workspaces_) {
      if (sameWorkspace(workspace.location, message.workspace)) {
        if (workspace.name != message.name) {
          ++view_version_.workspace;
        }

        workspace.name = message.name;
      }
    }

    for (const auto& descriptor : message.tabs) {
      auto& tab = ensureTab({message.workspace, descriptor.tab_id});
      if (tab.label != descriptor.label || tab.position != descriptor.position) {
        ++view_version_.tabs;
      }

      tab.label = descriptor.label;
      tab.position = descriptor.position;
      tab.observePanes(descriptor.panes);
      ++chrome_revision_;
    }

    if (current_workspace && !active_tab_ && (presented_ || leave_pending_) && !message.tabs.empty()) {
      selectTab({message.workspace, message.tabs.front().tab_id});
    }

    return Change::model;
  }

  Change Session::apply(const WorkspaceList& message) {
    return workspaces_.apply(message) ? Change::model : Change::none;
  }

  Change Session::apply(const ClientLayoutSnapshot& message) {
    if (active_tab_) {
      if (auto const* tab = activeTab()) {
        sendSnapshotRequest(RequestTabSnapshot{.location = tab->location});
        synchronizeAttachments();
      }

      return Change::model;
    }

    if (!restore_layout_ || !message.restored || !message.active_tab) {
      openDefault();

      return Change::none;
    }

    configuration_.sidebar_visible = message.sidebar_visible;
    ++view_version_.host;
    sidebar_columns_ = std::max(SidebarColumns::minimum_width, message.sidebar_width);
    workspace_list_collapsed_ = message.workspace_list_collapsed;
    for (const auto& saved : message.tabs) {
      PaneLayout validated;

      validated.restore(saved.nodes);
      if (!validated.contains(saved.focused_pane)) {
        throw EncodingError{"InvalidClientLayoutFocus"};
      }

      if (!saved_layouts_.remember({.location = saved.location, .pane_id = saved.focused_pane, .focused_pane = saved.focused_pane, .workspace_active = saved.workspace_active, .fullscreen = saved.fullscreen, .nodes = saved.nodes})) {
        throw EncodingError{"TooManySavedLayouts"};
      }

      if (saved.workspace_active) {
        navigation_history_.remember({.location = saved.location, .pane_id = saved.focused_pane, .layout = NavigationHistory::Layout{saved.nodes, saved.focused_pane}, .fullscreen = saved.fullscreen});
      }
    }

    if (presented_) {
      openRestoredWorkspace(*message.active_tab);
    } else {
      initial_open_pending_ = true;
      deferred_tab_ = message.active_tab;
    }

    return Change::sidebar;
  }

  Change Session::apply(const TabClosed& message) {
    complete(message.request_id);
    const auto active_closed = active_tab_ && sameTab(*active_tab_, message.location);
    const auto* closing = findTab(message.location);
    const bool closing_known = closing != nullptr;
    const auto position = closing_known ? closing->position : std::uint16_t{};
    const auto replacement = tabAfterRemoval(message.location, position);

    discardTab(message.location);
    if (closing_known) {
      for (auto& tab : tabs_) {
        if (sameWorkspace(tab->location.workspace, message.location.workspace) && tab->position > position) {
          --tab->position;
        }
      }
    }

    if (active_closed && message.workspace_closed) {
      if (!message.previous_workspace) {
        return Change::closed;
      }

      selectWorkspace({WorkspaceLocation::Kind::workspace, *message.previous_workspace});
    } else if (active_closed && replacement) {
      selectTab(*replacement);
    }

    synchronizeAttachments();
    retainLayout();

    return Change::model;
  }

  std::optional<TabLocation> Session::tabAfterRemoval(TabLocation closing, std::uint16_t position) const noexcept {
    const Tab<Memory>* previous = nullptr;
    const Tab<Memory>* next = nullptr;

    for (const auto& tab : tabs_) {
      if (!sameWorkspace(tab->location.workspace, closing.workspace) || sameTab(tab->location, closing)) {
        continue;
      }

      if (tab->position > position && (next == nullptr || tab->position < next->position)) {
        next = tab.get();
      } else if (tab->position < position && (previous == nullptr || tab->position > previous->position)) {
        previous = tab.get();
      }
    }

    const auto* selected = next == nullptr ? previous : next;

    return selected == nullptr ? std::nullopt : std::optional{selected->location};
  }

  void Session::discardTab(TabLocation location) {
    if (findTab(location) != nullptr) {
      ++view_version_.tabs;
      ++view_version_.panes;
    }

    for (const auto& pane : panes_) {
      if (!sameTab(pane->location, location)) {
        continue;
      }

      if (pane->attached) {
        prepareDetach(pane->id);
        send(DetachPane{pane->id});
      }
    }

    std::erase_if(tabs_, [&](const auto& tab) {
      return sameTab(tab->location, location);
    });

    removePanes([&](const Pane<Memory>& pane) {
      return sameTab(pane.location, location);
    });

    if (active_tab_ && sameTab(*active_tab_, location)) {
      active_tab_.reset();
    }
  }

  template <typename Removed>
  void Session::removePanes(Removed removed) {
    for (const auto& pane : panes_) {
      if (removed(*pane)) {
        forgetPane(pane->id);
      }
    }

    std::erase_if(panes_, [&](const auto& pane) {
      return removed(*pane);
    });

    forgetClosedGraphics();
  }

  Change Session::apply(const PaneExited& message) {
    if (auto* pane = findPane(message.pane_id)) {
      pane->exited = true;
      ++view_version_.panes;
    }

    for (auto& tab : tabs_) {
      tab->layout.remove(message.pane_id);
      if (tab->focused_pane == message.pane_id) {
        tab->focused_pane = tab->layout.firstPane();
      }
    }

    for (std::size_t index = pending_count_; index-- > 0;) {
      if (pending_[index].kind == RequestKind::close_pane && pending_[index].pane_id == message.pane_id) {
        complete(pending_[index].id);
      }
    }

    synchronizeAttachments();
    retainLayout();
    removePanes([&](const Pane<Memory>& pane) {
      return pane.id == message.pane_id;
    });

    return Change::model;
  }

  void Session::forgetPane(std::uint64_t pane_id) noexcept {
    cancelPaneRequests(pane_id);
    if (copy_mode_.state() && copy_mode_.state()->pane_id == pane_id) {
      copy_mode_.reset();
      copy_search_request_ = 0;
    }

    features::paths::forget(paths_, pane_id);

    const auto owned = [pane_id](const auto& entry) {
      return entry.second.pane_id == pane_id;
    };

    std::erase_if(command_requests_, owned);
    std::erase_if(spec_requests_, owned);
    std::erase_if(path_completions_, owned);
    command_checks_.erase(pane_id);
    spec_completions_.erase(pane_id);
    lines_.erase(pane_id);
  }

  void Session::cancelPaneRequests(std::uint64_t pane_id) noexcept {
    for (std::size_t index = pending_count_; index-- > 0;) {
      if (pending_[index].pane_id == pane_id && pending_[index].kind != RequestKind::split) {
        complete(pending_[index].id);
      }
    }
  }

  Change Session::apply(const TabRenamed& message) {
    const auto request = complete(message.request_id);
    if (!request || request->kind != RequestKind::rename_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabRenamed"};
    }

    if (auto* tab = findTab(message.location)) {
      if (tab->label != message.label) {
        ++view_version_.tabs;
      }

      tab->label = message.label;
    }

    return Change::model;
  }

  Change Session::apply(const TabMoved& message) {
    const auto request = complete(message.request_id);
    if (!request || request->kind != RequestKind::move_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabMoved"};
    }

    if (auto* tab = findTab(message.location)) {
      const auto count = std::ranges::count_if(tabs_, [&](const auto& entry) {
        return sameWorkspace(entry->location.workspace, message.location.workspace);
      });
      if (message.position >= count) {
        throw EncodingError{"Invalid tab position"};
      }

      const auto previous = tab->position;

      for (auto& entry : tabs_) {
        if (!sameWorkspace(entry->location.workspace, message.location.workspace) || entry.get() == tab) {
          continue;
        }

        if (previous < message.position && entry->position > previous && entry->position <= message.position) {
          --entry->position;
        } else if (previous > message.position && entry->position >= message.position && entry->position < previous) {
          ++entry->position;
        }
      }

      if (tab->position != message.position) {
        ++view_version_.tabs;
      }

      tab->position = message.position;
    }

    return Change::model;
  }

  Change Session::apply(const EditorOpened& message) {
    const auto request = editor_opening_.complete(message.request_id);
    if (!request) {
      return Change::none;
    }

    const auto& source = request->source;
    const auto* pane = findPane(source.pane_id);
    if (pane == nullptr || !active_tab_ || !sameTab(source.location, *active_tab_) || !sameTab(pane->location, source.location) || pane->generation != source.pane_generation || pane->attachment_generation != source.attachment_generation) {
      return Change::none;
    }

    switch (message.outcome) {
    case EditorOutcome::unavailable:
      try {
        splitEditorPane(*request);
      } catch (const std::exception& error) {
        return reportLinkFailure(error.what());
      }

      return Change::model;
    case EditorOutcome::failed:
      return reportLinkFailure("EditorOpenFailed");
    case EditorOutcome::missing:
      return reportLinkFailure("FileNotFound");
    case EditorOutcome::opened: {
      const auto* editor = findPane(message.pane_id);
      if (editor == nullptr || !sameTab(editor->location, source.location) || editor->generation != message.pane_generation) {
        return Change::none;
      }

      focusPane(editor->id);

      return Change::model;
    }
    }

    return Change::none;
  }

  Change Session::reportLinkFailure(std::string_view message) {
    publishNotification({.level = NotificationLevel::failure, .title = "Could not open link", .message = message, .link = {}});

    return Change::notification;
  }

  Change Session::apply(const ResyncRequired& message) {
    if (message.workspace_closed) {
      const auto active_closed = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);
      std::array<TabLocation, maximum_tabs> removed;
      std::size_t removed_count = 0;

      for (const auto& tab : tabs_) {
        if (sameWorkspace(tab->location.workspace, message.workspace)) {
          removed[removed_count++] = tab->location;
        }
      }

      for (const auto& location : std::span{removed}.first(removed_count)) {
        discardTab(location);
      }

      if (active_closed) {
        if (!message.previous_workspace) {
          return Change::closed;
        }

        selectWorkspace({WorkspaceLocation::Kind::workspace, *message.previous_workspace});
      }

      return Change::model;
    }

    if (const auto location = active_tab_) {
      sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = location->workspace});
      sendSnapshotRequest(RequestTabSnapshot{.location = *location});
    }

    for (const auto& pane : panes_) {
      if (pane->attached) {
        send(RequestSnapshot{pane->id, pane->screen.frameId()});
      }
    }

    return Change::model;
  }

  // The requests application::peek registers.
  template void Session::sendRegistered<InterruptAgent>(RequestKind kind, InterruptAgent request, std::uint64_t pane_id);
  template void Session::sendRegistered<SendPaneText>(RequestKind kind, SendPaneText request, std::uint64_t pane_id);
  template void Session::sendRegistered<LaunchWorktree>(RequestKind kind, LaunchWorktree request, std::uint64_t pane_id);

}
