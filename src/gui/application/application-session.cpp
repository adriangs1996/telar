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
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::application {

  template <typename Message>
  std::span<const Byte> Session::Link::encode(const Message& message) {
    return Codec::encode(message, transport.buffer(Codec::encodedSize(message)));
  }

  template <typename Message>
  void Session::Link::send(const Message& message) {
    transport.send(encode(message));
  }

  bool Session::Link::report(const ReportLimit& report) {
    return transport.report(encode(report));
  }

  Session::Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<MonotonicNow, tbc::lt::static_storage> now)
      : Session(memory, transport, discard_effects_, now) {}

  Session::Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<HostEffects&, tbc::lt::a> effects, tbc::view<MonotonicNow, tbc::lt::static_storage> now)
      : prompt(memory),
        prompt_lines(memory),
        copy_mode(memory),
        memory(memory),
        link(transport),
        effects_(effects),
        now_(now),
        panes(memory),
        tabs(memory),
        workspace_list(memory),
        agent_list(memory),
        pane_list_(memory),
        history(memory),
        peek(memory),
        monitor(memory),
        decode_(memory),
        clipboard_(memory),
        error_(memory),
        command_response_(memory),
        launch_defaults(memory) {
    decode_.resize(decode_capacity);
  }

  Session::LaunchDefaults::LaunchDefaults(tbc::view<Memory&, tbc::lt::a> memory)
      : memory_(&memory),
        cwd_(memory),
        storage_(memory) {}

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

  void Session::connected(std::uint64_t identity, bool reads_rows, bool monitors) {
    reads_rows_ = reads_rows;
    monitors_ = monitors;
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
          detachPane(copy_mode, link, pane->id);
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

  Change Session::consume(std::span<const Byte> payload) {
    UnsupportedClientCommand handler;

    return consume(payload, handler);
  }

  Change Session::consume(std::span<const Byte> payload, ClientCommandHandler& handler) {
    if (payload.empty()) {
      throw EncodingError{"Empty server message"};
    }

    DecodeStorage storage{decode_.viewMut()};
    const auto dispatch = [&]<typename Message> {
      return dispatchMessage<Message>(payload, storage, handler);
    };

    switch (static_cast<ServerTag>(payload.front())) {
    case ServerTag::pane_frame:
      return dispatch.template operator()<PaneFrame>();
    case ServerTag::client_command:
      return dispatch.template operator()<ClientCommand>();
    case ServerTag::pane_focus_command:
      return dispatch.template operator()<PaneFocusCommand>();
    case ServerTag::graphics_snapshot:
      return dispatch.template operator()<GraphicsSnapshot>();
    case ServerTag::graphics_image:
      return dispatch.template operator()<GraphicsImage>();
    case ServerTag::graphics_shared_image:
      return dispatch.template operator()<GraphicsSharedImage>();
    case ServerTag::graphics_image_chunk:
      return dispatch.template operator()<GraphicsImageChunk>();
    case ServerTag::graphics_placement:
      return dispatch.template operator()<GraphicsPlacementMessage>();
    case ServerTag::graphics_delete_image:
      return dispatch.template operator()<GraphicsDeleteImage>();
    case ServerTag::graphics_delete_placement:
      return dispatch.template operator()<GraphicsDeletePlacement>();
    case ServerTag::pane_opened:
      return dispatch.template operator()<PaneOpened>();
    case ServerTag::editor_opened:
      return dispatch.template operator()<EditorOpened>();
    case ServerTag::tab_created:
      return dispatch.template operator()<TabCreated>();
    case ServerTag::tab_snapshot:
      return dispatch.template operator()<TabSnapshot>();
    case ServerTag::workspace_snapshot:
      return dispatch.template operator()<WorkspaceSnapshot>();
    case ServerTag::workspace_list:
      return dispatch.template operator()<WorkspaceList>();
    case ServerTag::client_layout_snapshot:
      return dispatch.template operator()<ClientLayoutSnapshot>();
    case ServerTag::tab_closed:
      return dispatch.template operator()<TabClosed>();
    case ServerTag::tab_renamed:
      return dispatch.template operator()<TabRenamed>();
    case ServerTag::tab_moved:
      return dispatch.template operator()<TabMoved>();
    case ServerTag::pane_exited:
      return dispatch.template operator()<PaneExited>();
    case ServerTag::pane_title:
      return dispatch.template operator()<PaneTitle>();
    case ServerTag::pane_cwd:
      return dispatch.template operator()<PaneCwd>();
    case ServerTag::pane_foreground:
      return dispatch.template operator()<PaneForeground>();
    case ServerTag::pane_progress:
      return dispatch.template operator()<PaneProgress>();
    case ServerTag::pane_shell:
      return dispatch.template operator()<PaneShell>();
    case ServerTag::pane_git:
      return dispatch.template operator()<PaneGit>();
    case ServerTag::pane_blocks:
      return dispatch.template operator()<PaneBlocks>();
    case ServerTag::pane_scrollback:
      return dispatch.template operator()<PaneScrollback>();
    case ServerTag::pane_document:
      return dispatch.template operator()<PaneDocument>();
    case ServerTag::pane_rows:
      return dispatch.template operator()<PaneRows>();
    case ServerTag::command_spec:
      return dispatch.template operator()<CommandSpec>();
    case ServerTag::completion_words:
      return dispatch.template operator()<CompletionWords>();
    case ServerTag::pane_clipboard:
      return dispatch.template operator()<PaneClipboard>();
    case ServerTag::pane_matches:
      return dispatch.template operator()<PaneMatches>();
    case ServerTag::pane_text:
      return dispatch.template operator()<PaneText>();
    case ServerTag::agent_snapshot:
      return dispatch.template operator()<AgentSnapshot>();
    case ServerTag::pane_list:
      return dispatch.template operator()<PaneList>();
    case ServerTag::agent_sound:
      return dispatch.template operator()<AgentSoundNotification>();
    case ServerTag::history_results:
      return dispatch.template operator()<HistoryResults>();
    case ServerTag::history_output:
      return dispatch.template operator()<HistoryOutput>();
    case ServerTag::history_pruned:
      return dispatch.template operator()<HistoryPruned>();
    case ServerTag::path_results:
      return dispatch.template operator()<PathResults>();
    case ServerTag::command_suggestion:
      return dispatch.template operator()<CommandSuggestion>();
    case ServerTag::system_metrics:
      return dispatch.template operator()<SystemMetrics>();
    case ServerTag::monitor_snapshot:
      return dispatch.template operator()<MonitorSnapshot>();
    case ServerTag::proxy_status:
      return dispatch.template operator()<ProxyStatus>();
    case ServerTag::request_failed:
      return dispatch.template operator()<RequestFailed>();
    case ServerTag::request_completed:
      return dispatch.template operator()<RequestCompleted>();
    case ServerTag::resync_required:
      return dispatch.template operator()<ResyncRequired>();
    case ServerTag::notification:
      return dispatch.template operator()<Notification>();
    case ServerTag::runtime_stopping:
      return dispatch.template operator()<RuntimeStopping>();
    default:
      return Change::none;
    }
  }

  const Pane<Memory>* findPane(const Panes& panes, std::uint64_t pane_id) noexcept {
    const auto found = std::find_if(panes.begin(), panes.end(), [&](const auto& pane) {
      return pane->id == pane_id;
    });

    return found == panes.end() ? nullptr : &found->get();
  }

  Pane<Memory>* findPaneMut(Panes& panes, std::uint64_t pane_id) noexcept {
    const auto all = panes.viewMut();
    const auto found = std::find_if(all.begin(), all.end(), [&](const auto& pane) {
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

  tbc::view<const Tab<Memory>*, tbc::lt::a> activeTab(tbc::view<const Tabs&, tbc::lt::a> tabs, ds::Option<TabLocation> active) noexcept {
    return active ? features::workbench::find(tabs.view(), *active) : nullptr;
  }

  tbc::view<Tab<Memory>*, tbc::lt::a> activeTabMut(tbc::view<Tabs&, tbc::lt::a> tabs, ds::Option<TabLocation> active) noexcept {
    return active ? features::workbench::findMut(tabs.viewMut(), *active) : nullptr;
  }

  const Tab<Memory>* Session::activeTab() const noexcept {
    return application::activeTab(tabs, active_tab);
  }

  Tab<Memory>* Session::activeTabMut() noexcept {
    return application::activeTabMut(tabs, active_tab);
  }

  tbc::view<const Pane<Memory>*, tbc::lt::a> focusedPane(tbc::view<const Panes&, tbc::lt::a> panes, const Tabs& tabs, ds::Option<TabLocation> active) noexcept {
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
    if (configuration.sidebar_width != width) {
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

  bool Session::monitors() const noexcept {
    return monitors_;
  }

  Change Session::apply(const ProxyStatus& message) {
    proxy_ = message;
    return Change::model;
  }

  Change Session::apply(const RequestFailed& message) {
    if (features::monitor::fail(monitor, message.request_id, message.message)) {
      return Change::monitor;
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
      if (request->kind == RequestKind::peek_screen) {
        peek::readFailed(*this, message.request_id);

        return Change::none;
      }

      if (request->kind == RequestKind::peek_action || request->kind == RequestKind::peek_diff) {
        return peek::actionFailed(*this, request->pane_id, message.message);
      }

      if (recoverMissingWorkspacePane(*request, message)) {
        return Change::model;
      }

      if (request->kind == RequestKind::forget_worktree) {
        return Change::none;
      }

      if (request->kind == RequestKind::attach) {
        if (auto* pane = findPaneMut(request->pane_id)) {
          pane->attaching = false;
        }
      } else if (request->kind == RequestKind::tab_snapshot) {
        if (auto* tab = findTabMut(request->location)) {
          tab->loading = false;
        }
      } else if (request->kind == RequestKind::split) {
        workbench::recoverSplit(*this, request->location, request->pane_id);
      }
    }

    error_.assign(message.message);

    return Change::model;
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
