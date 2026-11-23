module telar.gui.application;

import std;
import telar.gui.features.notifications;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.tbc;
import telar.gui.features.terminal.graphics;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.gui.foundation.keys;
import telar.gui.features.paths;
import telar.gui.features.nvim;
import telar.gui.features.peek;
import telar.gui.features.palette;
import telar.config.client;
import telar.config.runtime;
import telar.base.text;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.graphics;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::application {

  Session::Link::Link(tbc::mut_a<RuntimeTransport> runtime_transport) noexcept
      : transport(runtime_transport) {}

  template <typename Message>
  std::span<const Byte> Session::Link::encode(const Message& message) {
    return Codec::encode(message, transport.buffer(Codec::encodedSize(message)));
  }

  template <typename Message>
  void Session::Link::send(const Message& message) {
    transport.send(encode(message));
  }

  template <typename Request>
  bool Session::Link::offer(const Request& request) {
    try {
      send(request);
    } catch (const std::length_error&) {
      return false;
    }

    return true;
  }

  template <typename Request>
  ds::Option<std::uint64_t> Session::Link::ask(Request request) {
    request.request_id = nextRequest();
    if (!offer(request)) {
      return ds::none;
    }

    return request.request_id;
  }

  bool Session::Link::report(const ReportLimit& report) {
    return transport.report(encode(report));
  }

  Session::Session(tbc::mut_a<Memory> allocator, tbc::mut_a<RuntimeTransport> transport, tbc::val_static<MonotonicNow> now)
      : Session(allocator, transport, discard_effects_, now) {}

  Session::Session(tbc::mut_a<Memory> allocator, tbc::mut_a<RuntimeTransport> transport, tbc::mut_a<HostEffects> effects, tbc::val_static<MonotonicNow> now)
      : prompt(allocator),
        prompt_lines(allocator),
        copy_mode(allocator),
        memory(allocator),
        link(transport),
        effects_(effects),
        now_(now),
        panes(allocator),
        tabs(allocator),
        workspace_list(allocator),
        agent_list(allocator),
        pane_list_(allocator),
        history(allocator),
        peek(allocator),
        monitor(allocator),
        explorer(allocator),
        nvim(allocator),
        decode_(allocator),
        clipboard_(allocator),
        error_(allocator),
        command_response_(allocator),
        launch_defaults(allocator) {
    decode_.resize(decode_capacity);
  }

  Session::LaunchDefaults::LaunchDefaults(tbc::mut_a<Memory> allocator)
      : memory_(&allocator),
        cwd_(allocator),
        storage_(allocator) {}

  Launch Session::LaunchDefaults::launch() const noexcept {
    static constexpr ds::Array<std::string_view, 1> default_shell{"/bin/sh"};
    const auto arguments = count_ == 0 ? std::span<const std::string_view>{default_shell} : std::span<const std::string_view>{arguments_}.first(count_);

    return {.cwd = cwd_.empty() ? std::string_view{"/"} : std::string_view{cwd_}, .arguments = arguments};
  }

  void Session::LaunchDefaults::set(const Launch& launch) {
    BodySchema<Launch>::validate(launch);
    cwd_.assign(launch.cwd);
    storeArguments(launch.arguments);
  }

  void Session::LaunchDefaults::setDirectory(std::string_view directory) {
    auto launch = this->launch();

    launch.cwd = directory;
    BodySchema<Launch>::validate(launch);
    cwd_.assign(directory);
  }

  void Session::LaunchDefaults::setArguments(std::span<const std::string_view> arguments) {
    auto launch = this->launch();

    launch.arguments = arguments;
    BodySchema<Launch>::validate(launch);
    storeArguments(arguments);
  }

  void Session::LaunchDefaults::storeArguments(std::span<const std::string_view> arguments) {
    storage_.clear();
    count_ = 0;
    storage_.reserve(arguments.size());
    for (const auto argument : arguments) {
      storage_.emplace(*memory_, argument);
    }

    for (const auto& argument : storage_) {
      arguments_.atMut(count_++) = argument;
    }
  }

  void Session::setLaunch(const Launch& launch) {
    launch_defaults.set(launch);
  }

  void Session::setLaunchDirectory(std::string_view directory) {
    launch_defaults.setDirectory(directory);
  }

  void Session::setLaunchArguments(std::span<const std::string_view> arguments) {
    launch_defaults.setArguments(arguments);
  }

  void Session::setRestoreLayout(bool enabled) noexcept {
    restore_layout_ = enabled;
  }

  void Session::connected(std::uint64_t identity, handshake::Dialect dialect) {
    dialect_ = dialect;
    panes.clear();
    tabs.clear();
    active_tab.reset();
    left_machine_.reset();
    deferred_tab_.reset();
    features::workbench::clear(workbench);
    initial_open_pending_ = false;
    workspace_list.resetSource();
    ++view_version.workspace;
    ++view_version.tabs;
    ++view_version.active_tab;
    ++view_version.panes;
    ready_ = true;
    status_bar = {};
    proxy_ = {};
    link.send(RequestRuntimeState{.client_identity = identity, .interactive = true});
    link.send(ConfigureGraphics{supportsSharedGraphics()});
    window::pace(*this);
    prompt::configureShell(*this);
    configuration::configureTerminal(*this);
  }

  bool Session::requestsPending() const noexcept {
    return !link.requests().empty();
  }

  bool Session::presented() const noexcept {
    return presented_;
  }

  void Session::setPresented(bool presented) {
    if (presented_ == presented) {
      if (!presented) {
        static_cast<void>(settlePresentation());
      }

      return;
    }

    presented_ = presented;
    leave_pending_ = !presented;
    if (!presented) {
      peek::close(*this);
    }

    if (presented) {
      if (ready_) {
        restoreMachinePresentation();
      }
    } else {
      static_cast<void>(settlePresentation());
    }
  }

  bool Session::settlePresentation() {
    if (!leave_pending_ || presented_ || (ready_ && !link.requests().empty())) {
      return false;
    }

    const auto bookmark = machineBookmark();

    if (ready_) {
      workbench::retainLayout(*this);
      for (auto& pane : panes.viewMut()) {
        if (pane->attached || pane->attaching) {
          detachPane(copy_mode, nvim, link, pane->id);
          pane.getMut().attached = false;
          pane.getMut().attaching = false;
        }
      }
    }

    if (bookmark) {
      left_machine_ = bookmark;
    }

    releaseWorkspacePresentation();
    leave_pending_ = false;

    return true;
  }

  void Session::disconnected() noexcept {
    ++view_version.host;
    ready_ = false;
    features::terminal::graphics::suspend(graphics);
    agent_list.resetSource();
    pane_list_.resetSource();
    workspace_list.resetSource();
    features::terminal::copy_mode::close(copy_mode);
    features::history::suspend(history);
    features::paths::close(paths);
    features::peek::close(peek);
    features::monitor::reset(monitor);
    features::explorer::reset(explorer);
    features::nvim::detach(nvim);
    features::palette::discard(palette);
    link.forgetRequests();
    features::terminal::links::suspend(links);
    features::prompt::failAll(prompt, prompt_lines);
    for (auto& pane : panes.viewMut()) {
      pane.getMut().attached = false;
      pane.getMut().attaching = false;
      pane.getMut().snapshot_requested = false;
      pane.getMut().acknowledged_frame = 0;
      pane.getMut().screen.detach();
      pane.getMut().graphics.detach();
      pane.getMut().rows.release();
      pane.getMut().scrollback_generation = 0;
    }

    for (auto& tab : tabs.viewMut()) {
      tab.getMut().loading = false;
    }
  }

  namespace {
    // The messages a window has no use for: answers to requests it never sends, and what the
    // runtime tells a client of another kind. Every message the wire names is routed by
    // Session::consume or here, so one added to ServerTag is routed or ignored on purpose, or does
    // not compile.
    constexpr ds::Array ignored_messages{
        ServerTag::notification_shown,
        ServerTag::history_stats_result,
        ServerTag::pane_focus_result,
        ServerTag::client_list,
        ServerTag::client_command_result,
        ServerTag::worktree_registered,
        ServerTag::limit_list,
        ServerTag::execution_reply,
        ServerTag::clipboard_desktop_request,
        ServerTag::clipboard_desktop_execute,
        ServerTag::clipboard_desktop_cancel,
        ServerTag::runtime_clipboard_chunk,
        ServerTag::pane_theme,
        ServerTag::history_workspaces,
    };

    // Whether each message of ServerTag is routed by `routes`, a handler per tag, or listed in
    // ignored_messages, and never both.
    template <typename Routes>
    consteval bool placesEachMessage(const Routes& routes) {
      for (std::size_t value = 0; value < routes.size(); ++value) {
        const auto tag = static_cast<ServerTag>(value); // NOLINT(clang-analyzer-optin.core.EnumCastOutOfRange): every byte is tried, and serverTagName tells the ones that name a tag
        const bool routed = routes.at(value) != nullptr;
        const bool skipped = std::ranges::find(ignored_messages, tag) != ignored_messages.end();

        if (serverTagName(tag).empty() ? routed || skipped : routed == skipped) {
          return false;
        }
      }

      return true;
    }
  }

  Change Session::consume(std::span<const Byte> payload) {
    UnsupportedClientCommand handler;

    return consume(payload, handler);
  }

  // The runtime's messages by tag, each with what applies it. One the window has no use for is
  // in ignored_messages.
  consteval Session::DispatchTable Session::routed() {
    constexpr auto by_tag = []<typename... Messages>(std::type_identity<Messages>...) consteval -> DispatchTable {
      static_assert((std::same_as<std::remove_const_t<decltype(MessageSchema<Messages>::tag)>, ServerTag> && ...), "only the runtime's messages");
      DispatchTable table{};

      ((table.atMut(std::to_underlying(MessageSchema<Messages>::tag)) = &Session::dispatchMessage<Messages>), ...);
      if (std::ranges::count(table, Dispatch{}) != table.size() - sizeof...(Messages)) {
        throw std::logic_error{"Two messages share a tag"};
      }

      return table;
    };

    return by_tag(
        std::type_identity<PaneFrame>{},
        std::type_identity<ClientCommand>{},
        std::type_identity<PaneFocusCommand>{},
        std::type_identity<GraphicsSnapshot>{},
        std::type_identity<GraphicsImage>{},
        std::type_identity<GraphicsSharedImage>{},
        std::type_identity<GraphicsImageChunk>{},
        std::type_identity<GraphicsPlacementMessage>{},
        std::type_identity<GraphicsDeleteImage>{},
        std::type_identity<GraphicsDeletePlacement>{},
        std::type_identity<PaneOpened>{},
        std::type_identity<EditorOpened>{},
        std::type_identity<TabCreated>{},
        std::type_identity<TabSnapshot>{},
        std::type_identity<WorkspaceSnapshot>{},
        std::type_identity<WorkspaceList>{},
        std::type_identity<ClientLayoutSnapshot>{},
        std::type_identity<TabClosed>{},
        std::type_identity<TabRenamed>{},
        std::type_identity<TabMoved>{},
        std::type_identity<PaneExited>{},
        std::type_identity<PaneTitle>{},
        std::type_identity<PaneCwd>{},
        std::type_identity<PaneForeground>{},
        std::type_identity<PaneProgress>{},
        std::type_identity<PaneShell>{},
        std::type_identity<PaneGit>{},
        std::type_identity<PaneBlocks>{},
        std::type_identity<PaneScrollback>{},
        std::type_identity<PaneDocument>{},
        std::type_identity<PaneRows>{},
        std::type_identity<CommandSpec>{},
        std::type_identity<CompletionWords>{},
        std::type_identity<PaneClipboard>{},
        std::type_identity<PaneMatches>{},
        std::type_identity<PaneText>{},
        std::type_identity<AgentSnapshot>{},
        std::type_identity<PaneList>{},
        std::type_identity<AgentSoundNotification>{},
        std::type_identity<HistoryResults>{},
        std::type_identity<HistoryOutput>{},
        std::type_identity<HistoryPruned>{},
        std::type_identity<PathResults>{},
        std::type_identity<CommandSuggestion>{},
        std::type_identity<SystemMetrics>{},
        std::type_identity<MonitorSnapshot>{},
        std::type_identity<DirectoryContents>{},
        std::type_identity<DirectorySizes>{},
        std::type_identity<RepositoryChanges>{},
        std::type_identity<FileInspection>{},
        std::type_identity<FilesChanged>{},
        std::type_identity<ChangesCommitted>{},
        std::type_identity<HomeLocated>{},
        std::type_identity<PaneKindNotice>{},
        std::type_identity<NvimGrid>{},
        std::type_identity<NvimFrame>{},
        std::type_identity<NvimCmdline>{},
        std::type_identity<NvimPopupMenu>{},
        std::type_identity<NvimMessageList>{},
        std::type_identity<NvimTabLine>{},
        std::type_identity<NvimPrompt>{},
        std::type_identity<NvimNavigated>{},
        std::type_identity<NvimPick>{},
        std::type_identity<NvimLink>{},
        std::type_identity<TextResults>{},
        std::type_identity<ProxyStatus>{},
        std::type_identity<RequestFailed>{},
        std::type_identity<RequestCompleted>{},
        std::type_identity<ResyncRequired>{},
        std::type_identity<Notification>{},
        std::type_identity<RuntimeStopping>{}
    );
  }

  Change Session::consume(std::span<const Byte> payload, ClientCommandHandler& handler) {
    if (payload.empty()) {
      throw EncodingError{"Empty server message"};
    }

    static constexpr auto messages = routed();

    static_assert(placesEachMessage(messages), "Each message of ServerTag is routed in `messages` or listed in ignored_messages, and never both");

    DecodeStorage storage{decode_.viewMut()};
    const auto dispatch = messages[payload.front()];

    return dispatch == nullptr ? Change::none : (this->*dispatch)(payload, storage, handler);
  }

  const Pane<Memory>* findPane(const Panes& panes, std::uint64_t pane_id) noexcept {
    const auto* const found = std::ranges::find_if(panes, [&](const auto& pane) {
      return pane->id == pane_id;
    });

    return found == panes.end() ? nullptr : &found->get();
  }

  Pane<Memory>* findPaneMut(Panes& panes, std::uint64_t pane_id) noexcept {
    const auto all = panes.viewMut();
    const auto found = std::ranges::find_if(all, [&](const auto& pane) {
      return pane->id == pane_id;
    });

    return found == all.end() ? nullptr : &found->getMut();
  }

  const Pane<Memory>* Session::findPane(std::uint64_t pane_id) const noexcept {
    return application::findPane(panes, pane_id);
  }

  Pane<Memory>* Session::findPaneMut(std::uint64_t pane_id) noexcept {
    return application::findPaneMut(panes, pane_id);
  }

  tbc::val_a<const Tab<Memory>*> activeTab(tbc::ref_a<Tabs> tabs, ds::Option<TabLocation> active) noexcept {
    return active ? features::workbench::find(tabs.view(), *active) : nullptr;
  }

  tbc::val_a<Tab<Memory>*> activeTabMut(tbc::mut_a<Tabs> tabs, ds::Option<TabLocation> active) noexcept {
    return active ? features::workbench::findMut(tabs.viewMut(), *active) : nullptr;
  }

  const Tab<Memory>* Session::activeTab() const noexcept {
    return application::activeTab(tabs, active_tab);
  }

  Tab<Memory>* Session::activeTabMut() noexcept {
    return application::activeTabMut(tabs, active_tab);
  }

  tbc::val_a<const Pane<Memory>*> focusedPane(tbc::ref_a<Panes> panes, const Tabs& tabs, ds::Option<TabLocation> active) noexcept {
    const auto* tab = application::activeTab(tabs, active);

    return tab == nullptr ? nullptr : application::findPane(panes, tab->focused_pane);
  }

  const Pane<Memory>* Session::focusedPane() const noexcept {
    return application::focusedPane(panes, tabs, active_tab);
  }

  Pane<Memory>* Session::focusedPaneMut() noexcept {
    const auto* tab = activeTab();

    return tab == nullptr ? nullptr : findPaneMut(tab->focused_pane);
  }

  const ds::Vec<Workspace<Memory>, Memory>& Session::workspaces() const noexcept {
    return workspace_list.entries();
  }

  const ds::Vec<Agent<Memory>, Memory>& Session::agents() const noexcept {
    return agent_list.entries();
  }

  std::uint64_t Session::agentRevision() const noexcept {
    return agent_list.revision();
  }

  std::span<const ListedPane> Session::paneList() const noexcept {
    return pane_list_.entries();
  }

  std::uint64_t Session::paneListRevision() const noexcept {
    return pane_list_.revision();
  }

  std::string_view Session::clipboard() const noexcept {
    return clipboard_;
  }

  std::uint64_t Session::chromeRevision() const noexcept {
    return chrome_revision_;
  }

  std::string_view Session::error() const noexcept {
    return error_;
  }

  void Session::dismissDiagnostic() noexcept {
    error_.clear();
  }

  bool Session::ready() const noexcept {
    return ready_;
  }

  std::uint64_t Session::changedPane() const noexcept {
    return changed_pane_;
  }

  ClientViewState Session::clientViewState() const noexcept {
    return {.sidebar_visible = configuration.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .pane_gaps = configuration.pane_gaps, .window_title = configuration.window_title.view()};
  }

  ViewVersion Session::viewVersion() const noexcept {
    return view_version;
  }

  void Session::invalidateView() noexcept {
    ++view_version.host;
  }

  void Session::setSidebarVisible(bool visible) {
    if (configuration.sidebar_visible != visible) {
      ++view_version.host;
    }

    configuration.sidebar_visible = visible;
    workbench::retainLayout(*this);
  }

  void Session::setSidebarWidth(float width) {
    if (std::not_equal_to<>{}(configuration.sidebar_width, width)) {
      ++view_version.host;
    }

    configuration.sidebar_width = width;
  }

  void Session::setHostColumns(std::uint16_t columns) noexcept {
    host_columns_ = columns;
  }

  bool Session::workspaceListCollapsed() const noexcept {
    return workspace_list_collapsed_;
  }

  void Session::setWorkspaceListCollapsed(bool collapsed) {
    if (workspace_list_collapsed_ == collapsed) {
      return;
    }

    workspace_list_collapsed_ = collapsed;
    workbench::retainLayout(*this);
  }

  const ProxyStatus& Session::proxyStatus() const noexcept {
    return proxy_;
  }

  std::uint64_t Session::Link::nextRequest() noexcept {
    return ++request_id_;
  }

  auto Session::Link::requests() const noexcept -> std::span<const Pending> {
    return std::span{pending_}.first(pending_count_);
  }

  auto Session::Link::lastPending() noexcept -> Pending& {
    return pending_.atMut(pending_count_ - 1);
  }

  void Session::Link::forgetRequests() noexcept {
    pending_count_ = 0;
  }

  std::uint64_t Session::Link::pending(RequestKind kind, std::uint64_t pane_id, ClientLayoutAxis axis) {
    if (pending_count_ == pending_.size()) {
      throw std::length_error{"Pending GUI request capacity reached"};
    }

    const auto request = nextRequest();

    pending_.atMut(pending_count_++) = {.id = request, .kind = kind, .pane_id = pane_id, .axis = axis};

    return request;
  }

  auto Session::Link::complete(std::uint64_t request_id) noexcept -> ds::Option<Pending> {
    for (std::size_t index = 0; index < pending_count_; ++index) {
      if (pending_[index].id == request_id) {
        const auto result = pending_[index];

        pending_.atMut(index) = pending_[--pending_count_];

        return result;
      }
    }

    return {};
  }

  template <typename Message>
  Change Session::dispatchMessage(std::span<const Byte> payload, DecodeStorage& storage, ClientCommandHandler& handler) {
    if constexpr (std::same_as<Message, GraphicsSnapshot> || std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsSharedImage> || std::same_as<Message, GraphicsImageChunk> || std::same_as<Message, GraphicsPlacementMessage> || std::same_as<Message, GraphicsDeleteImage> || std::same_as<Message, GraphicsDeletePlacement>) {
      try {
        const auto change = apply(Codec::decode<Message>(payload, storage));

        terminal::graphics::resume(*this);

        return change;
      } catch (const std::exception& error) {
        recoverRuntime(error.what());

        throw;
      }
    } else if constexpr (std::same_as<Message, ClientCommand>) {
      return apply(Codec::decode<Message>(payload, storage), handler);
    } else {
      return apply(Codec::decode<Message>(payload, storage));
    }
  }

  void Session::recoverRuntime(std::string_view reason) {
    if (!ready_) {
      return;
    }

    ready_ = false;
    link.transport.recover(reason);
  }

  Change Session::apply(const SystemMetrics& message) {
    return status_bar::receive(*this, message);
  }

  Change Session::apply(const MonitorSnapshot& message) {
    return features::monitor::receive(monitor, message) ? Change::monitor : Change::none;
  }

  Change Session::apply(const PaneKindNotice& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimGrid& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimFrame& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimCmdline& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimPopupMenu& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimMessageList& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimTabLine& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimPrompt& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimNavigated& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimPick& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const NvimLink& message) {
    return nvim::receive(*this, message);
  }

  Change Session::apply(const TextResults& message) {
    return nvim::receive(*this, message);
  }

  bool Session::monitors() const noexcept {
    return speaks(ClientTag::query_monitor);
  }

  bool Session::explores() const noexcept {
    return speaks(ClientTag::list_directory);
  }

  Change Session::apply(const DirectoryContents& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const DirectorySizes& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const RepositoryChanges& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const FileInspection& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const FilesChanged& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const ChangesCommitted& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  Change Session::apply(const HomeLocated& message) {
    return features::explorer::receive(explorer, message) ? Change::explorer : Change::none;
  }

  bool Session::speaks(ClientTag tag) const noexcept {
    return dialect_ && handshake::speaks(*dialect_, tag);
  }

  Change Session::apply(const ProxyStatus& message) {
    proxy_ = message;
    return Change::model;
  }

  Change Session::apply(const RequestFailed& message) {
    if (features::monitor::fail(monitor, message.request_id, message.message)) {
      return Change::monitor;
    }

    if (features::explorer::fail(explorer, message)) {
      return Change::explorer;
    }

    for (auto& pane : panes.viewMut()) {
      if (pane.getMut().rows.settle(message.request_id)) {
        return Change::none;
      }
    }

    if (const auto change = paths::fail(*this, message)) {
      return *change;
    }

    if (const auto change = history::fail(*this, message.request_id, message.message)) {
      return *change;
    }

    if (const auto change = prompt::fail(*this, message.request_id)) {
      return *change;
    }

    if (const auto change = terminal::links::fail(*this, message.request_id, message.message)) {
      return *change;
    }

    if (const auto request = link.complete(message.request_id)) {
      if (const auto change = failPending(*request, message)) {
        return *change;
      }
    }

    error_.assign(message.message);

    return Change::model;
  }

  ds::Option<Change> Session::failPending(const Pending& request, const RequestFailed& message) {
    if (request.kind == RequestKind::peek_screen) {
      peek::readFailed(*this, message.request_id);

      return Change::none;
    }

    if (request.kind == RequestKind::peek_action || request.kind == RequestKind::peek_diff) {
      return peek::actionFailed(*this, request.pane_id, message.message);
    }

    if (recoverMissingWorkspacePane(request, message)) {
      return Change::model;
    }

    if (request.kind == RequestKind::forget_worktree) {
      return Change::none;
    }

    if (request.kind == RequestKind::attach) {
      if (auto* pane = findPaneMut(request.pane_id)) {
        pane->attaching = false;
      }
    } else if (request.kind == RequestKind::tab_snapshot) {
      if (auto* tab = findTabMut(request.location)) {
        tab->loading = false;
      }
    } else if (request.kind == RequestKind::split) {
      workbench::recoverSplit(*this, request.location, request.pane_id);
    }

    return ds::none;
  }

  Change Session::apply(const RequestCompleted& message) {
    if (features::monitor::complete(monitor, message.request_id)) {
      return Change::monitor;
    }

    const auto request = link.complete(message.request_id);
    if (request && request->kind == RequestKind::forget_worktree) {
      return Change::none;
    }

    if (request && request->kind == RequestKind::close_pane) {
      ++view_version.panes;
      for (auto& tab : tabs.viewMut()) {
        tab.getMut().layout.remove(request->pane_id);
        if (tab->focused_pane == request->pane_id) {
          tab.getMut().focused_pane = tab->layout.firstPane();
        }
      }

      synchronizeAttachments();
      workbench::retainLayout(*this);
    }

    return Change::model;
  }

  Change Session::apply([[maybe_unused]] const RuntimeStopping& message) {
    disconnected();

    return Change::stopped;
  }

  // The messages the other units of the session send.
  // Limit reports go out through the transport's report, which may drop them.
  template std::span<const Byte> Session::Link::encode<ReportLimit>(const ReportLimit& message);

  template void Session::Link::send<AcknowledgeAgent>(const AcknowledgeAgent& message);
  template void Session::Link::send<ClosePane>(const ClosePane& message);
  template void Session::Link::send<CloseTab>(const CloseTab& message);
  template void Session::Link::send<CompleteClientCommand>(const CompleteClientCommand& message);
  template void Session::Link::send<CompletePaneFocus>(const CompletePaneFocus& message);
  template void Session::Link::send<CompleteWords>(const CompleteWords& message);
  template void Session::Link::send<ConfigureFrameInterval>(const ConfigureFrameInterval& message);
  template void Session::Link::send<ConfigureShellPrompt>(const ConfigureShellPrompt& message);
  template void Session::Link::send<ConfigureTerminalColors>(const ConfigureTerminalColors& message);
  template bool Session::Link::offer<CompleteWords>(const CompleteWords& request);
  template bool Session::Link::offer<FindPaths>(const FindPaths& request);
  template bool Session::Link::offer<QueryHistory>(const QueryHistory& request);
  template ds::Option<std::uint64_t> Session::Link::ask<NvimConfiguration>(NvimConfiguration request);
  template ds::Option<std::uint64_t> Session::Link::ask<QueryMonitor>(QueryMonitor request);
  template ds::Option<std::uint64_t> Session::Link::ask<FindPaths>(FindPaths request);
  template ds::Option<std::uint64_t> Session::Link::ask<ListDirectory>(ListDirectory request);
  template ds::Option<std::uint64_t> Session::Link::ask<MeasureDirectory>(MeasureDirectory request);
  template ds::Option<std::uint64_t> Session::Link::ask<QueryChanges>(QueryChanges request);
  template ds::Option<std::uint64_t> Session::Link::ask<InspectFile>(InspectFile request);
  template ds::Option<std::uint64_t> Session::Link::ask<ChangeFiles>(ChangeFiles request);
  template ds::Option<std::uint64_t> Session::Link::ask<UndoFileChanges>(UndoFileChanges request);
  template ds::Option<std::uint64_t> Session::Link::ask<CommitChanges>(CommitChanges request);
  template ds::Option<std::uint64_t> Session::Link::ask<LocateHome>(LocateHome request);
  template ds::Option<std::uint64_t> Session::Link::ask<RequestProcessPriority>(RequestProcessPriority request);
  template ds::Option<std::uint64_t> Session::Link::ask<RequestProcessSignal>(RequestProcessSignal request);
  template void Session::Link::send<CopySelection>(const CopySelection& message);
  template void Session::Link::send<CreatePane>(const CreatePane& message);
  template void Session::Link::send<CreateTab>(const CreateTab& message);
  template void Session::Link::send<CreateWorkspace>(const CreateWorkspace& message);
  template void Session::Link::send<DeleteHistory>(const DeleteHistory& message);
  template void Session::Link::send<DetachPane>(const DetachPane& message);
  template void Session::Link::send<FindPaths>(const FindPaths& message);
  template void Session::Link::send<ForgetWorktree>(const ForgetWorktree& message);
  template void Session::Link::send<FrameAck>(const FrameAck& message);
  template void Session::Link::send<GraphicsCredit>(const GraphicsCredit& message);
  template void Session::Link::send<InterruptAgent>(const InterruptAgent& message);
  template void Session::Link::send<LaunchWorktree>(const LaunchWorktree& message);
  template void Session::Link::send<MoveTab>(const MoveTab& message);
  template void Session::Link::send<CreateNvimPane>(const CreateNvimPane& message);
  template void Session::Link::send<NvimFocus>(const NvimFocus& message);
  template void Session::Link::send<NvimInput>(const NvimInput& message);
  template void Session::Link::send<NvimMouse>(const NvimMouse& message);
  template void Session::Link::send<NvimBuffers>(const NvimBuffers& message);
  template void Session::Link::send<NvimList>(const NvimList& message);
  template void Session::Link::send<NvimPreview>(const NvimPreview& message);
  template void Session::Link::send<FindText>(const FindText& message);
  template void Session::Link::send<NvimMenuSelect>(const NvimMenuSelect& message);
  template void Session::Link::send<NvimNavigate>(const NvimNavigate& message);
  template void Session::Link::send<NvimOpen>(const NvimOpen& message);
  template void Session::Link::send<NvimPaste>(const NvimPaste& message);
  template void Session::Link::send<NvimPromptReply>(const NvimPromptReply& message);
  template void Session::Link::send<OpenEditor>(const OpenEditor& message);
  template void Session::Link::send<OpenPane>(const OpenPane& message);
  template void Session::Link::send<PaneCommand>(const PaneCommand& message);
  template void Session::Link::send<PaneInput>(const PaneInput& message);
  template void Session::Link::send<PaneResize>(const PaneResize& message);
  template void Session::Link::send<QueryHistory>(const QueryHistory& message);
  template void Session::Link::send<ReadHistoryOutput>(const ReadHistoryOutput& message);
  template void Session::Link::send<ReadPane>(const ReadPane& message);
  template void Session::Link::send<ReadPaneRows>(const ReadPaneRows& message);
  template void Session::Link::send<RenameTab>(const RenameTab& message);
  template void Session::Link::send<RenameWorkspace>(const RenameWorkspace& message);
  template void Session::Link::send<RequestCommandSpec>(const RequestCommandSpec& message);
  template void Session::Link::send<RequestGraphicsSnapshot>(const RequestGraphicsSnapshot& message);
  template void Session::Link::send<RequestSnapshot>(const RequestSnapshot& message);
  template void Session::Link::send<RequestTabSnapshot>(const RequestTabSnapshot& message);
  template void Session::Link::send<RequestWorkspaceSnapshot>(const RequestWorkspaceSnapshot& message);
  template void Session::Link::send<SearchPane>(const SearchPane& message);
  template void Session::Link::send<SearchPaneRows>(const SearchPaneRows& message);
  template void Session::Link::send<SendPaneText>(const SendPaneText& message);
  template void Session::Link::send<SetPaneViewport>(const SetPaneViewport& message);
  template void Session::Link::send<SuggestCommand>(const SuggestCommand& message);
  template void Session::Link::send<UpdateClientLayout>(const UpdateClientLayout& message);

}
