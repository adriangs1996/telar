module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.foundation.actions;
import telar.tbc;
import telar.gui.features.terminal.graphics;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.gui.features.workbench;
import telar.gui.features.terminal.links;
import telar.gui.features.paths;
import telar.gui.features.palette;
import telar.config.client;
import telar.config.runtime;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.editor;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::application {

  template <typename Request, typename Fill>
  void Session::Link::sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id, Fill&& fill) {
    request.request_id = pending(kind, pane_id);
    std::forward<Fill>(fill)(lastPending(), std::as_const(request));
    try {
      send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  template <typename Request>
  void Session::Link::sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id) {
    sendRegistered(kind, request, pane_id, [](Pending&, const Request&) {});
  }

  template <typename Request>
    requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
  void Session::Link::sendOpeningRequest(RequestKind kind, Request request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace) {
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
  void Session::Link::sendSnapshotRequest(Request request) {
    constexpr auto kind = std::same_as<Request, RequestTabSnapshot> ? RequestKind::tab_snapshot : RequestKind::workspace_snapshot;

    sendRegistered(kind, request, 0, [](Pending& registered, const Request& sent) {
      if constexpr (std::same_as<Request, RequestTabSnapshot>) {
        registered.location = sent.location;
      } else {
        registered.location.workspace = sent.workspace;
      }
    });
  }

  bool Session::Link::completeRequest(RequestKind kind, std::uint64_t request_id) noexcept {
    const auto waiting = requests();
    const auto found = std::ranges::find_if(waiting, [&](const Pending& request) {
      return request.id == request_id && request.kind == kind;
    });
    if (found == waiting.end()) {
      return false;
    }

    complete(request_id);

    return true;
  }

  Pane<Memory>& Session::allocateSplitPane(const Pending& request, const PaneOpened& message) {
    try {
      return ensurePane(message.pane_id, message.location);
    } catch (...) {
      workbench::recoverSplit(*this, request.location, request.pane_id);
      link.send(DetachPane{message.pane_id});
      throw;
    }
  }

  Change Session::adoptSplit(const Pending& request, const PaneOpened& message) {
    if (!message.created || message.pane_id == 0 || message.pane_id == request.pane_id || !sameTab(message.location, request.location)) {
      throw EncodingError{"UnexpectedPaneSplit"};
    }

    auto* tab = findTabMut(request.location);
    if (tab == nullptr) {
      if (findPane(message.pane_id) == nullptr) {
        link.send(DetachPane{message.pane_id});
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

    if (active_tab && sameTab(*active_tab, tab->location)) {
      confirmAttachment(pane);
      workbench::setFocus(*this, tab->location, pane.id);
      workbench::resizeVisible(*this);
    } else {
      link.send(DetachPane{pane.id});
    }

    ++view_version.panes;
    synchronizeAttachments();
    workbench::retainLayout(*this);

    if (message.pane_generation == 0) {
      link.sendSnapshotRequest(RequestTabSnapshot{.location = message.location});
    }

    return Change::model;
  }

  template <typename Request>
  void Session::Link::sendTabOperation(RequestKind kind, Request request) {
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
  void Session::reserveAppend(ds::Vec<Value, Memory>& values, std::size_t maximum) {
    if (values.size() < values.capacity()) {
      return;
    }

    constexpr std::size_t growth_factor = 2;
    const auto grown = values.capacity() > maximum / growth_factor ? maximum : values.capacity() * growth_factor;

    values.reserve(std::max(values.size() + 1, grown));
  }

  const Tab<Memory>* Session::findTab(TabLocation location) const noexcept {
    return features::workbench::find(tabs.view(), location);
  }

  Tab<Memory>* Session::findTabMut(TabLocation location) noexcept {
    return features::workbench::findMut(tabs.viewMut(), location);
  }

  Tab<Memory>& Session::ensureTab(TabLocation location) {
    if (auto* tab = findTabMut(location)) {
      return *tab;
    }

    if (tabs.size() == maximum_tabs) {
      throw std::length_error{"GUI tab capacity reached"};
    }

    tabs.push(ds::makeBox<Tab<Memory>>(memory, memory, location));
    features::workbench::furnish(workbench, tabs.backMut().getMut());
    ++view_version.tabs;

    return tabs.backMut().getMut();
  }

  Pane<Memory>& Session::ensurePane(std::uint64_t pane_id, TabLocation location) {
    if (auto* pane = findPaneMut(pane_id)) {
      return *pane;
    }

    if (panes.size() == maximum_panes) {
      throw std::length_error{"GUI pane capacity reached"};
    }

    panes.push(ds::makeBox<Pane<Memory>>(memory, memory, pane_id, graphics_budget_));
    panes.backMut().getMut().location = location;
    ++view_version.panes;

    return panes.backMut().getMut();
  }

  void Session::openDefault() {
    if (!presented_) {
      initial_open_pending_ = true;
      deferred_tab_.reset();

      return;
    }

    const auto launch = launch_defaults.launch();

    link.sendOpeningRequest(RequestKind::open_default, OpenPane{.size = features::workbench::launchSize(workbench), .launch = launch});
  }

  auto Session::machineBookmark() const noexcept -> ds::Option<MachineBookmark> {
    const auto* tab = activeTab();
    if (tab == nullptr) {
      return ds::none;
    }

    ds::Option<std::uint64_t> fallback;

    if (tab->location.workspace.kind == WorkspaceLocation::Kind::workspace) {
      fallback = tab->location.workspace.id;
    } else if (const auto* row = workspace_list.worktree(tab->location.workspace.id)) {
      fallback = row->source;
    }

    return MachineBookmark{.location = tab->location, .pane_id = tab->focused_pane, .fallback_workspace = fallback};
  }

  bool Session::recoverMissingWorkspacePane(const Pending& request, const RequestFailed& failure) {
    if ((request.kind != RequestKind::restore_machine && request.kind != RequestKind::visit_pane) || !request.fallback_workspace || failure.code != FailureCode::pane_not_found) {
      return false;
    }

    features::workbench::forget(workbench, {.kind = WorkspaceLocation::Kind::workspace, .id = *request.fallback_workspace});
    link.sendOpeningRequest(RequestKind::open_default, OpenPane{.target = {.kind = PaneTarget::Kind::workspace, .id = *request.fallback_workspace}, .size = features::workbench::launchSize(workbench)});

    return true;
  }

  void Session::handoffPane(std::uint64_t pane_id, ds::Option<std::uint64_t> fallback_workspace) {
    handoffWorkspace({.kind = PaneTarget::Kind::pane, .id = pane_id}, fallback_workspace);
  }

  void Session::handoffWorkspace(PaneTarget target, ds::Option<std::uint64_t> fallback_workspace) {
    const OpenPane opening{.target = target, .size = features::workbench::launchSize(workbench)};

    try {
      workbench::retainLayout(*this);
      for (auto& pane : panes.viewMut()) {
        if (pane->attached || pane->attaching) {
          detachPane(copy_mode, link, pane->id);
          pane.getMut().attached = false;
          pane.getMut().attaching = false;
        }
      }

      link.sendOpeningRequest(RequestKind::visit_pane, opening, TabLocation(), fallback_workspace);
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

    features::workbench::leave(workbench, tabs, active_tab, tab != nullptr && findPane(tab->focused_pane) != nullptr ? tab : nullptr);
    panes.clear();
    tabs.clear();
    active_tab.reset();
    features::terminal::copy_mode::close(copy_mode);
    features::history::suspend(history);
    features::paths::close(paths);
    features::palette::discard(palette);
    features::terminal::graphics::suspend(graphics);
    features::terminal::links::suspend(links);
    ++view_version.workspace;
    ++view_version.tabs;
    ++view_version.active_tab;
    ++view_version.panes;
    ++view_version.host;
  }

  void Session::restoreMachinePresentation() {
    if (active_tab) {
      synchronizeAttachments();

      return;
    }

    if (std::ranges::any_of(link.requests(), [](const Pending& request) {
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
      const auto target = bookmark.pane_id != 0 ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = bookmark.pane_id} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = bookmark.fallback_workspace.valueOr(bookmark.location.workspace.id)};

      link.sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = target, .size = features::workbench::launchSize(workbench)}, bookmark.location, bookmark.fallback_workspace);
    }
  }

  void Session::openRestoredWorkspace(TabLocation location) {
    const auto saved = features::workbench::savedPane(workbench, location);
    if (!saved) {
      throw EncodingError{"InvalidClientLayoutActiveTab"};
    }

    const auto fallback = location.workspace.kind == WorkspaceLocation::Kind::workspace ? ds::Option{location.workspace.id} : ds::none;

    link.sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = {.kind = PaneTarget::Kind::pane, .id = *saved}, .size = features::workbench::launchSize(workbench)}, location, fallback);
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

  void Session::synchronizeAttachments() {
    if (!presented_) {
      return;
    }

    activity::acknowledge(*this);
    const auto* active = activeTab();

    for (auto& pane : panes.viewMut()) {
      const auto visible = active != nullptr && active->layout.contains(pane->id) && (!active->fullscreen || pane->id == active->focused_pane);
      if (visible && !pane->attached && !pane->attaching && !pane->exited) {
        pane.getMut().attaching = true;
        try {
          link.sendOpeningRequest(RequestKind::attach, OpenPane{.target = {.kind = PaneTarget::Kind::pane, .id = pane->id}, .size = pane->size});
        } catch (...) {
          pane.getMut().attaching = false;
          throw;
        }
      } else if (!visible && pane->attached) {
        detachPane(copy_mode, link, pane->id);
        pane.getMut().attached = false;
        pane.getMut().acknowledged_frame = 0;
        pane.getMut().screen.detach();
        pane.getMut().graphics.detach();
      }
    }
  }

  void Session::detachPane(features::terminal::copy_mode::State& copy_mode, Link& link, std::uint64_t pane_id) {
    if (const auto& copy = features::terminal::copy_mode::view(copy_mode).state(); copy && copy->pane_id == pane_id) {
      features::terminal::copy_mode::close(copy_mode);
    }

    link.transport.willDetach(pane_id);
    link.send(DetachPane{pane_id});
  }

  Change Session::apply(const PaneOpened& message) {
    const auto request = link.complete(message.request_id);
    if (!request) {
      if (findPane(message.pane_id) == nullptr) {
        link.send(DetachPane{message.pane_id});
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
      ++view_version.panes;
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
      features::workbench::stage(workbench, tab);
    }

    const auto axis = request ? request->axis : ClientLayoutAxis::horizontal;
    const auto beside = request && request->kind == RequestKind::split ? request->pane_id : tab.focused_pane;

    tab.layout.add(pane.id, axis, beside);

    if (!tab.loading && !tab.loaded) {
      tab.loading = true;
      link.sendSnapshotRequest(RequestTabSnapshot{.location = tab.location});
      link.sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = tab.location.workspace});
    }

    if (request->kind != RequestKind::attach) {
      workbench::setFocus(*this, tab.location, pane.id);
      workbench::selectTab(*this, message.location);
      left_machine_.reset();
    }

    synchronizeAttachments();
    resize(pane.id, desired_size);
    workbench::retainLayout(*this);

    return Change::model;
  }

  Change Session::apply(const TabCreated& message) {
    const auto request = link.complete(message.request_id);
    const auto* previous = activeTab();
    if (!request || request->kind != RequestKind::create_tab || !sameWorkspace(request->location.workspace, message.location.workspace) || previous == nullptr || !sameWorkspace(previous->location.workspace, message.location.workspace)) {
      throw EncodingError{"UnexpectedTabCreated"};
    }

    const auto* const cached = std::ranges::find_if(tabs, [&](const auto& tab) {
      return sameTab(tab->location, message.location);
    });

    const bool discovered = cached != tabs.end();
    if ((discovered && ((*cached)->loaded || (*cached)->loading || !(*cached)->layout.nodes().empty())) || findPane(message.root_pane_id) != nullptr) {
      throw EncodingError{"Tab or pane already exists"};
    }

    const auto cached_index = static_cast<std::size_t>(cached - tabs.begin());
    const auto count = static_cast<std::size_t>(std::ranges::count_if(tabs, [&](const auto& tab) {
      return sameWorkspace(tab->location.workspace, message.location.workspace);
    })) - static_cast<std::size_t>(discovered);
    if (count >= maximum_workspace_tabs || message.position > count || (!discovered && tabs.size() == maximum_tabs) || panes.size() == maximum_panes) {
      throw EncodingError{"Invalid tab position or capacity"};
    }

    auto tab = ds::makeBox<Tab<Memory>>(memory, memory, message.location);

    tab.getMut().label.assign(message.label);
    tab.getMut().position = message.position;
    if (discovered) {
      tab.getMut().foreground.assign((*cached)->foreground);
      tab.getMut().foreground_pane = (*cached)->foreground_pane;
    }

    tab.getMut().layout.add(message.root_pane_id, ClientLayoutAxis::horizontal, tab->focused_pane);
    tab.getMut().focused_pane = message.root_pane_id;
    tab.getMut().loaded = true;
    auto pane = ds::makeBox<Pane<Memory>>(memory, memory, message.root_pane_id, graphics_budget_);

    pane.getMut().generation = message.pane_generation;
    pane.getMut().location = message.location;
    pane.getMut().size = request->size;
    if (!discovered) {
      reserveAppend(tabs, maximum_tabs);
    }

    reserveAppend(panes, maximum_panes);
    confirmAttachment(pane.getMut());

    if (discovered) {
      tabs.atMut(cached_index) = std::move(tab);
    } else {
      for (auto& existing : tabs.viewMut()) {
        if (sameWorkspace(existing->location.workspace, message.location.workspace) && existing->position >= message.position) {
          ++existing.getMut().position;
        }
      }

      features::workbench::furnish(workbench, tab.getMut());
      tabs.push(std::move(tab));
    }

    panes.push(std::move(pane));
    ++view_version.tabs;
    ++view_version.panes;
    workbench::selectTab(*this, message.location);
    synchronizeAttachments();
    workbench::retainLayout(*this);

    return Change::model;
  }

  Change Session::apply(const TabSnapshot& message) {
    link.completeRequest(RequestKind::tab_snapshot, message.request_id);
    if (!presented_ && !leave_pending_) {
      return Change::none;
    }

    auto& tab = ensureTab(message.location);

    features::workbench::restore(workbench, tab, [&](std::uint64_t pane_id) {
      workbench::setFocus(*this, tab.location, pane_id);
    });

    tab.loaded = true;
    tab.loading = false;
    ++chrome_revision_;
    ds::Array<std::uint64_t, PaneLayout::maximum_panes> removed{};
    std::size_t removed_count = 0;

    for (const auto& node : tab.layout.nodes()) {
      const auto* leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf != nullptr && std::ranges::none_of(message.panes, [&](const auto& pane) {
            return pane.pane_id == leaf->pane_id;
          })) {
        removed.atMut(removed_count++) = leaf->pane_id;
      }
    }

    for (const auto identity : std::span{removed}.first(removed_count)) {
      tab.layout.remove(identity);
      ++view_version.panes;
    }

    for (const auto& descriptor : message.panes) {
      auto& pane = ensurePane(descriptor.pane_id, message.location);
      if (pane.generation != descriptor.pane_generation || pane.exited != (descriptor.lifecycle == PaneLifecycle::exited)) {
        ++view_version.panes;
      }

      pane.generation = descriptor.pane_generation;
      pane.exited = descriptor.lifecycle == PaneLifecycle::exited;
      tab.layout.add(pane.id, ClientLayoutAxis::horizontal, tab.layout.firstPane());
    }

    if (!tab.layout.contains(tab.focused_pane)) {
      workbench::setFocus(*this, tab.location, tab.layout.firstPane());
    }

    synchronizeAttachments();
    workbench::retainLayout(*this);
    removePanes([&](const Pane<Memory>& pane) {
      return sameTab(pane.location, message.location) && !tab.layout.contains(pane.id);
    });

    return Change::model;
  }

  Change Session::apply(const WorkspaceSnapshot& message) {
    const bool current_workspace = active_tab && sameWorkspace(active_tab->workspace, message.workspace);

    link.completeRequest(RequestKind::workspace_snapshot, message.request_id);
    ds::Array<TabLocation, maximum_tabs> removed;
    std::size_t removed_count = 0;

    for (const auto& tab : tabs) {
      if (sameWorkspace(tab->location.workspace, message.workspace) && std::ranges::none_of(message.tabs, [&](const auto& entry) {
            return entry.tab_id == tab->location.tab_id;
          })) {
        removed.atMut(removed_count++) = tab->location;
      }
    }

    for (const auto& location : std::span{removed}.first(removed_count)) {
      discardTab(location);
    }

    for (auto& workspace : workspace_list.entriesMut()) {
      if (sameWorkspace(workspace.location, message.workspace)) {
        if (workspace.name != message.name) {
          ++view_version.workspace;
        }

        workspace.name.assign(message.name);
      }
    }

    for (const auto& descriptor : message.tabs) {
      auto& tab = ensureTab({.workspace = message.workspace, .tab_id = descriptor.tab_id});
      if (tab.label != descriptor.label || tab.position != descriptor.position) {
        ++view_version.tabs;
      }

      tab.label.assign(descriptor.label);
      tab.position = descriptor.position;
      tab.observePanes(descriptor.panes);
      ++chrome_revision_;
    }

    if (current_workspace && !active_tab && (presented_ || leave_pending_) && !message.tabs.empty()) {
      workbench::selectTab(*this, {.workspace = message.workspace, .tab_id = message.tabs.front().tab_id});
    }

    return Change::model;
  }

  Change Session::apply(const WorkspaceList& message) {
    return workspace_list.apply(message) ? Change::model : Change::none;
  }

  Change Session::apply(const ClientLayoutSnapshot& message) {
    if (active_tab) {
      if (auto const* tab = activeTab()) {
        link.sendSnapshotRequest(RequestTabSnapshot{.location = tab->location});
        synchronizeAttachments();
      }

      return Change::model;
    }

    if (!restore_layout_ || !message.restored || !message.active_tab) {
      openDefault();

      return Change::none;
    }

    configuration.sidebar_visible = message.sidebar_visible;
    ++view_version.host;
    sidebar_columns_ = std::max(SidebarColumns::minimum_width, message.sidebar_width);
    workspace_list_collapsed_ = message.workspace_list_collapsed;
    features::workbench::adopt(workbench, message.tabs);

    if (presented_) {
      openRestoredWorkspace(*message.active_tab);
    } else {
      initial_open_pending_ = true;
      deferred_tab_ = message.active_tab;
    }

    return Change::sidebar;
  }

  Change Session::apply(const TabClosed& message) {
    link.complete(message.request_id);
    const auto active_closed = active_tab && sameTab(*active_tab, message.location);
    const auto* closing = findTab(message.location);
    const bool closing_known = closing != nullptr;
    const auto position = closing_known ? closing->position : std::uint16_t{};
    const auto replacement = features::workbench::tabAfterClose(tabs, message.location, position);

    discardTab(message.location);
    if (closing_known) {
      for (auto& tab : tabs.viewMut()) {
        if (sameWorkspace(tab->location.workspace, message.location.workspace) && tab->position > position) {
          --tab.getMut().position;
        }
      }
    }

    if (active_closed && message.workspace_closed) {
      if (!message.previous_workspace) {
        return Change::closed;
      }

      workbench::selectWorkspace(*this, {.kind = WorkspaceLocation::Kind::workspace, .id = *message.previous_workspace});
    } else if (active_closed && replacement) {
      workbench::selectTab(*this, *replacement);
    }

    synchronizeAttachments();
    workbench::retainLayout(*this);

    return Change::model;
  }

  void Session::discardTab(TabLocation location) {
    if (findTab(location) != nullptr) {
      ++view_version.tabs;
      ++view_version.panes;
    }

    for (const auto& pane : panes) {
      if (!sameTab(pane->location, location)) {
        continue;
      }

      if (pane->attached) {
        detachPane(copy_mode, link, pane->id);
      }
    }

    tabs.retain([&](const auto& tab) {
      return !sameTab(tab->location, location);
    });

    removePanes([&](const Pane<Memory>& pane) {
      return sameTab(pane.location, location);
    });

    if (active_tab && sameTab(*active_tab, location)) {
      active_tab.reset();
    }
  }

  template <typename Removed>
  void Session::removePanes(Removed removed) {
    for (std::size_t index = 0; index < panes.size(); ++index) { // NOLINT(modernize-loop-convert): by index, as forgetting a pane reaches the session, though not its panes.
      if (const auto& pane = *panes[index]; removed(pane)) {
        const auto pane_id = pane.id;

        forgetPane(pane_id);
      }
    }

    panes.retain([&](const auto& pane) {
      return !removed(*pane);
    });

    terminal::graphics::forgetClosed(*this);
  }

  Change Session::apply(const PaneExited& message) {
    if (auto* pane = findPaneMut(message.pane_id)) {
      pane->exited = true;
      ++view_version.panes;
    }

    for (auto& tab : tabs.viewMut()) {
      tab.getMut().layout.remove(message.pane_id);
      if (tab->focused_pane == message.pane_id) {
        tab.getMut().focused_pane = tab->layout.firstPane();
      }
    }

    for (std::size_t index = link.requests().size(); index-- > 0;) {
      if (const auto request = link.requests()[index]; request.kind == RequestKind::close_pane && request.pane_id == message.pane_id) {
        link.complete(request.id);
      }
    }

    synchronizeAttachments();
    workbench::retainLayout(*this);
    removePanes([&](const Pane<Memory>& pane) {
      return pane.id == message.pane_id;
    });

    return Change::model;
  }

  void Session::forgetPane(std::uint64_t pane_id) noexcept {
    cancelPaneRequests(pane_id);
    if (const auto& copy = features::terminal::copy_mode::view(copy_mode).state(); copy && copy->pane_id == pane_id) {
      features::terminal::copy_mode::close(copy_mode);
    }

    features::paths::forget(paths, pane_id);
    features::prompt::forget(prompt, prompt_lines, pane_id);
    features::nvim::forget(nvim, pane_id);
  }

  void Session::cancelPaneRequests(std::uint64_t pane_id) noexcept {
    for (std::size_t index = link.requests().size(); index-- > 0;) {
      if (const auto request = link.requests()[index]; request.pane_id == pane_id && request.kind != RequestKind::split) {
        link.complete(request.id);
      }
    }
  }

  Change Session::apply(const TabRenamed& message) {
    const auto request = link.complete(message.request_id);
    if (!request || request->kind != RequestKind::rename_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabRenamed"};
    }

    if (auto* tab = findTabMut(message.location)) {
      if (tab->label != message.label) {
        ++view_version.tabs;
      }

      tab->label.assign(message.label);
    }

    return Change::model;
  }

  Change Session::apply(const TabMoved& message) {
    const auto request = link.complete(message.request_id);
    if (!request || request->kind != RequestKind::move_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabMoved"};
    }

    if (auto* tab = findTabMut(message.location)) {
      const auto count = std::ranges::count_if(tabs, [&](const auto& entry) {
        return sameWorkspace(entry->location.workspace, message.location.workspace);
      });
      if (std::cmp_greater_equal(message.position, count)) {
        throw EncodingError{"Invalid tab position"};
      }

      const auto previous = tab->position;

      for (auto& entry : tabs.viewMut()) {
        if (!sameWorkspace(entry->location.workspace, message.location.workspace) || &entry.get() == tab) {
          continue;
        }

        if (previous < message.position && entry->position > previous && entry->position <= message.position) {
          --entry.getMut().position;
        } else if (previous > message.position && entry->position >= message.position && entry->position < previous) {
          ++entry.getMut().position;
        }
      }

      if (tab->position != message.position) {
        ++view_version.tabs;
      }

      tab->position = message.position;
    }

    return Change::model;
  }

  Change Session::apply(const EditorOpened& message) {
    return terminal::links::receive(*this, message);
  }

  Change Session::apply(const ResyncRequired& message) {
    if (message.workspace_closed) {
      const auto active_closed = active_tab && sameWorkspace(active_tab->workspace, message.workspace);
      ds::Array<TabLocation, maximum_tabs> removed;
      std::size_t removed_count = 0;

      for (const auto& tab : tabs) {
        if (sameWorkspace(tab->location.workspace, message.workspace)) {
          removed.atMut(removed_count++) = tab->location;
        }
      }

      for (const auto& location : std::span{removed}.first(removed_count)) {
        discardTab(location);
      }

      if (active_closed) {
        if (!message.previous_workspace) {
          return Change::closed;
        }

        workbench::selectWorkspace(*this, {.kind = WorkspaceLocation::Kind::workspace, .id = *message.previous_workspace});
      }

      return Change::model;
    }

    if (const auto location = active_tab) {
      link.sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = location->workspace});
      link.sendSnapshotRequest(RequestTabSnapshot{.location = *location});
    }

    for (const auto& pane : panes) {
      if (pane->attached) {
        link.send(RequestSnapshot{.pane_id = pane->id, .known_frame_id = pane->screen.frameId()});
      }
    }

    return Change::model;
  }

  // The requests application::peek registers.
  template void Session::Link::sendRegistered<InterruptAgent>(RequestKind kind, InterruptAgent request, std::uint64_t pane_id);
  template void Session::Link::sendRegistered<SendPaneText>(RequestKind kind, SendPaneText request, std::uint64_t pane_id);
  template void Session::Link::sendRegistered<LaunchWorktree>(RequestKind kind, LaunchWorktree request, std::uint64_t pane_id);

  // The requests application::workbench registers and sends.
  template void Session::Link::sendRegistered<ClosePane>(RequestKind kind, ClosePane request, std::uint64_t pane_id);
  template void Session::Link::sendRegistered<ForgetWorktree>(RequestKind kind, ForgetWorktree request, std::uint64_t pane_id);
  template void Session::Link::sendOpeningRequest<OpenPane>(RequestKind kind, OpenPane request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace);
  template void Session::Link::sendOpeningRequest<CreateWorkspace>(RequestKind kind, CreateWorkspace request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace);
  template void Session::Link::sendSnapshotRequest<RequestTabSnapshot>(RequestTabSnapshot request);
  template void Session::Link::sendTabOperation<CreateTab>(RequestKind kind, CreateTab request);
  template void Session::Link::sendTabOperation<RenameTab>(RequestKind kind, RenameTab request);
  template void Session::Link::sendTabOperation<MoveTab>(RequestKind kind, MoveTab request);
  template void Session::Link::sendTabOperation<CloseTab>(RequestKind kind, CloseTab request);

}
