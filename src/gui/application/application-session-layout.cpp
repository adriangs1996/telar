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
  void Session::sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id, Fill&& fill) {
    request.request_id = pending(kind, pane_id);
    fill(pending_.atMut(pending_count_ - 1), std::as_const(request));
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

  template <typename Request>
    requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
  void Session::sendOpeningRequest(RequestKind kind, Request request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace) {
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

  Pane<Memory>& Session::allocateSplitPane(const Pending& request, const PaneOpened& message) {
    try {
      return ensurePane(message.pane_id, message.location);
    } catch (...) {
      workbench::recoverSplit(*this, request.location, request.pane_id);
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
      workbench::setFocus(*this, *tab, pane.id);
      workbench::resizeVisible(*this, *tab);
    } else {
      send(DetachPane{pane.id});
    }

    ++view_version_.panes;
    synchronizeAttachments();
    workbench::retainLayout(*this);

    if (message.pane_generation == 0) {
      sendSnapshotRequest(RequestTabSnapshot{.location = message.location});
    }

    return Change::model;
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
  void Session::reserveAppend(ds::Vec<Value, Memory>& values, std::size_t maximum) {
    if (values.size() < values.capacity()) {
      return;
    }

    constexpr std::size_t growth_factor = 2;
    const auto grown = values.capacity() > maximum / growth_factor ? maximum : values.capacity() * growth_factor;

    values.reserve(std::max(values.size() + 1, grown));
  }

  Tab<Memory>* Session::findTab(TabLocation location) const noexcept {
    return features::workbench::find(tabs_, location);
  }

  Tab<Memory>& Session::ensureTab(TabLocation location) {
    if (auto* tab = findTab(location)) {
      return *tab;
    }

    if (tabs_.size() == maximum_tabs) {
      throw std::length_error{"GUI tab capacity reached"};
    }

    tabs_.push(makeOwned<Tab<Memory>>(memory_, memory_, location));
    features::workbench::furnish(workbench_, *tabs_.back());
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

    panes_.push(makeOwned<Pane<Memory>>(memory_, memory_, pane_id, features::terminal::graphics::budget(graphics_)));
    panes_.back()->location = location;
    ++view_version_.panes;

    return *panes_.back();
  }

  void Session::openDefault() {
    if (!presented_) {
      initial_open_pending_ = true;
      deferred_tab_.reset();

      return;
    }

    const auto launch = defaultLaunch();

    sendOpeningRequest(RequestKind::open_default, OpenPane{.size = features::workbench::launchSize(workbench_), .launch = launch});
  }

  auto Session::machineBookmark() const noexcept -> ds::Option<MachineBookmark> {
    const auto* tab = activeTab();
    if (tab == nullptr) {
      return ds::none;
    }

    ds::Option<std::uint64_t> fallback;

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

    features::workbench::forget(workbench_, {.kind = WorkspaceLocation::Kind::workspace, .id = *request.fallback_workspace});
    sendOpeningRequest(RequestKind::open_default, OpenPane{.target = {.kind = PaneTarget::Kind::workspace, .id = *request.fallback_workspace}, .size = features::workbench::launchSize(workbench_)});

    return true;
  }

  void Session::handoffPane(std::uint64_t pane_id, ds::Option<std::uint64_t> fallback_workspace) {
    handoffWorkspace({.kind = PaneTarget::Kind::pane, .id = pane_id}, fallback_workspace);
  }

  void Session::handoffWorkspace(PaneTarget target, ds::Option<std::uint64_t> fallback_workspace) {
    const OpenPane opening{.target = target, .size = features::workbench::launchSize(workbench_)};

    try {
      workbench::retainLayout(*this);
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

    features::workbench::leave(workbench_, tabs_, active_tab_, tab != nullptr && findPane(tab->focused_pane) != nullptr ? tab : nullptr);
    panes_.clear();
    tabs_.clear();
    active_tab_.reset();
    features::terminal::copy_mode::close(copy_mode_);
    features::history::suspend(history_);
    features::paths::close(paths_);
    features::palette::discard(palette_);
    features::terminal::graphics::suspend(graphics_);
    features::terminal::links::suspend(links_);
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
      const auto target = bookmark.pane_id != 0 ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = bookmark.pane_id} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = bookmark.fallback_workspace.valueOr(bookmark.location.workspace.id)};

      sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = target, .size = features::workbench::launchSize(workbench_)}, bookmark.location, bookmark.fallback_workspace);
    }
  }

  void Session::openRestoredWorkspace(TabLocation location) {
    const auto saved = features::workbench::savedPane(workbench_, location);
    if (!saved) {
      throw EncodingError{"InvalidClientLayoutActiveTab"};
    }

    const auto fallback = location.workspace.kind == WorkspaceLocation::Kind::workspace ? ds::Option{location.workspace.id} : ds::none;

    sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = {.kind = PaneTarget::Kind::pane, .id = *saved}, .size = features::workbench::launchSize(workbench_)}, location, fallback);
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
    static constexpr ds::Array<std::string_view, 1> default_shell{"/bin/sh"};
    const auto arguments = launch_argument_count_ == 0 ? std::span<const std::string_view>{default_shell} : std::span<const std::string_view>{launch_arguments_}.first(launch_argument_count_);

    return {.cwd = launch_cwd_.empty() ? std::string_view{"/"} : std::string_view{launch_cwd_}, .arguments = arguments};
  }

  void Session::synchronizeAttachments() {
    if (!presented_) {
      return;
    }

    activity::acknowledge(*this);
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
    if (const auto& copy = features::terminal::copy_mode::view(copy_mode_).state(); copy && copy->pane_id == pane_id) {
      features::terminal::copy_mode::close(copy_mode_);
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
      features::workbench::stage(workbench_, tab);
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
      workbench::setFocus(*this, tab, pane.id);
      workbench::selectTab(*this, message.location);
      left_machine_.reset();
    }

    synchronizeAttachments();
    resize(pane.id, desired_size);
    workbench::retainLayout(*this);

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

    tab->label.assign(message.label);
    tab->position = message.position;
    if (discovered) {
      tab->foreground.assign((*cached)->foreground);
      tab->foreground_pane = (*cached)->foreground_pane;
    }

    tab->layout.add(message.root_pane_id, ClientLayoutAxis::horizontal, tab->focused_pane);
    tab->focused_pane = message.root_pane_id;
    tab->loaded = true;
    auto pane = makeOwned<Pane<Memory>>(memory_, memory_, message.root_pane_id, features::terminal::graphics::budget(graphics_));

    pane->generation = message.pane_generation;
    pane->location = message.location;
    pane->size = request->size;
    if (!discovered) {
      reserveAppend(tabs_, maximum_tabs);
    }

    reserveAppend(panes_, maximum_panes);
    confirmAttachment(*pane);

    if (discovered) {
      tabs_.atMut(cached_index) = std::move(tab);
    } else {
      for (auto& existing : tabs_) {
        if (sameWorkspace(existing->location.workspace, message.location.workspace) && existing->position >= message.position) {
          ++existing->position;
        }
      }

      features::workbench::furnish(workbench_, *tab);
      tabs_.push(std::move(tab));
    }

    panes_.push(std::move(pane));
    ++view_version_.tabs;
    ++view_version_.panes;
    workbench::selectTab(*this, message.location);
    synchronizeAttachments();
    workbench::retainLayout(*this);

    return Change::model;
  }

  Change Session::apply(const TabSnapshot& message) {
    completeRequest(RequestKind::tab_snapshot, message.request_id);
    if (!presented_ && !leave_pending_) {
      return Change::none;
    }

    auto& tab = ensureTab(message.location);

    features::workbench::restore(workbench_, tab, [&](std::uint64_t pane_id) {
      workbench::setFocus(*this, tab, pane_id);
    });
    tab.loaded = true;
    tab.loading = false;
    ++chrome_revision_;
    ds::Array<std::uint64_t, PaneLayout::maximum_panes> removed{};
    std::size_t removed_count = 0;

    for (const auto& node : tab.layout.nodes()) {
      const auto* leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf != nullptr && std::none_of(message.panes.begin(), message.panes.end(), [&](const auto& pane) {
            return pane.pane_id == leaf->pane_id;
          })) {
        removed.atMut(removed_count++) = leaf->pane_id;
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
      workbench::setFocus(*this, tab, tab.layout.firstPane());
    }

    synchronizeAttachments();
    workbench::retainLayout(*this);
    removePanes([&](const Pane<Memory>& pane) {
      return sameTab(pane.location, message.location) && !tab.layout.contains(pane.id);
    });

    return Change::model;
  }

  Change Session::apply(const WorkspaceSnapshot& message) {
    const bool current_workspace = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);

    completeRequest(RequestKind::workspace_snapshot, message.request_id);
    ds::Array<TabLocation, maximum_tabs> removed;
    std::size_t removed_count = 0;

    for (const auto& tab : tabs_) {
      if (sameWorkspace(tab->location.workspace, message.workspace) && std::none_of(message.tabs.begin(), message.tabs.end(), [&](const auto& entry) {
            return entry.tab_id == tab->location.tab_id;
          })) {
        removed.atMut(removed_count++) = tab->location;
      }
    }

    for (const auto& location : std::span{removed}.first(removed_count)) {
      discardTab(location);
    }

    for (auto& workspace : workspaces_.entriesMut()) {
      if (sameWorkspace(workspace.location, message.workspace)) {
        if (workspace.name != message.name) {
          ++view_version_.workspace;
        }

        workspace.name.assign(message.name);
      }
    }

    for (const auto& descriptor : message.tabs) {
      auto& tab = ensureTab({message.workspace, descriptor.tab_id});
      if (tab.label != descriptor.label || tab.position != descriptor.position) {
        ++view_version_.tabs;
      }

      tab.label.assign(descriptor.label);
      tab.position = descriptor.position;
      tab.observePanes(descriptor.panes);
      ++chrome_revision_;
    }

    if (current_workspace && !active_tab_ && (presented_ || leave_pending_) && !message.tabs.empty()) {
      workbench::selectTab(*this, {message.workspace, message.tabs.front().tab_id});
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
    features::workbench::adopt(workbench_, message.tabs);

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
    const auto replacement = features::workbench::tabAfterClose(tabs_, message.location, position);

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

      workbench::selectWorkspace(*this, {WorkspaceLocation::Kind::workspace, *message.previous_workspace});
    } else if (active_closed && replacement) {
      workbench::selectTab(*this, *replacement);
    }

    synchronizeAttachments();
    workbench::retainLayout(*this);

    return Change::model;
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

    tabs_.retain([&](const auto& tab) {
      return !sameTab(tab->location, location);
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

    panes_.retain([&](const auto& pane) {
      return !removed(*pane);
    });

    terminal::graphics::forgetClosed(*this);
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
    workbench::retainLayout(*this);
    removePanes([&](const Pane<Memory>& pane) {
      return pane.id == message.pane_id;
    });

    return Change::model;
  }

  void Session::forgetPane(std::uint64_t pane_id) noexcept {
    cancelPaneRequests(pane_id);
    if (const auto& copy = features::terminal::copy_mode::view(copy_mode_).state(); copy && copy->pane_id == pane_id) {
      features::terminal::copy_mode::close(copy_mode_);
    }

    features::paths::forget(paths_, pane_id);
    features::prompt::forget(prompt_, pane_id);
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

      tab->label.assign(message.label);
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
    return terminal::links::receive(*this, message);
  }

  Change Session::apply(const ResyncRequired& message) {
    if (message.workspace_closed) {
      const auto active_closed = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);
      ds::Array<TabLocation, maximum_tabs> removed;
      std::size_t removed_count = 0;

      for (const auto& tab : tabs_) {
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

        workbench::selectWorkspace(*this, {WorkspaceLocation::Kind::workspace, *message.previous_workspace});
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

  // The requests application::workbench registers and sends.
  template void Session::sendRegistered<ClosePane>(RequestKind kind, ClosePane request, std::uint64_t pane_id);
  template void Session::sendRegistered<ForgetWorktree>(RequestKind kind, ForgetWorktree request, std::uint64_t pane_id);
  template void Session::sendOpeningRequest<OpenPane>(RequestKind kind, OpenPane request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace);
  template void Session::sendOpeningRequest<CreateWorkspace>(RequestKind kind, CreateWorkspace request, TabLocation location, ds::Option<std::uint64_t> fallback_workspace);
  template void Session::sendSnapshotRequest<RequestTabSnapshot>(RequestTabSnapshot request);
  template void Session::sendTabOperation<CreateTab>(RequestKind kind, CreateTab request);
  template void Session::sendTabOperation<RenameTab>(RequestKind kind, RenameTab request);
  template void Session::sendTabOperation<MoveTab>(RequestKind kind, MoveTab request);
  template void Session::sendTabOperation<CloseTab>(RequestKind kind, CloseTab request);

}
