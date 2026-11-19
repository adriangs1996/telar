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
  std::span<const Byte> Session::encode(const Message& message) {
    return Codec::encode(message, transport_.buffer(Codec::encodedSize(message)));
  }

  template <typename Message>
  void Session::send(const Message& message) {
    transport_.send(encode(message));
  }

  Session::Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<MonotonicNow, tbc::lt::static_storage> now)
      : Session(memory, transport, discard_effects_, now) {}

  Session::Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<HostEffects&, tbc::lt::a> effects, tbc::view<MonotonicNow, tbc::lt::static_storage> now)
      : prompt_(memory),
        copy_mode_(memory),
        memory_(memory),
        transport_(transport),
        effects_(effects),
        now_(now),
        panes_(memory),
        tabs_(memory),
        workspaces_(memory),
        agents_(memory),
        pane_list_(memory),
        history_(memory),
        peek_(memory),
        decode_(memory),
        clipboard_(memory),
        error_(memory),
        command_response_(memory),
        launch_cwd_(memory),
        argument_storage_(memory) {
    decode_.resize(decode_capacity);
  }

  void Session::setLaunch(const Launch& launch) {
    BodySchema<Launch>::validate(launch);
    launch_cwd_.assign(launch.cwd);
    argument_storage_.clear();
    launch_argument_count_ = 0;
    argument_storage_.reserve(launch.arguments.size());
    for (const auto argument : launch.arguments) {
      argument_storage_.emplace(memory_, argument);
    }

    for (const auto& argument : argument_storage_) {
      launch_arguments_.atMut(launch_argument_count_++) = argument;
    }
  }

  void Session::setLaunchDirectory(std::string_view directory) {
    auto launch = defaultLaunch();

    launch.cwd = directory;
    BodySchema<Launch>::validate(launch);
    launch_cwd_.assign(directory);
  }

  void Session::setLaunchArguments(std::span<const std::string_view> arguments) {
    auto launch = defaultLaunch();

    launch.arguments = arguments;
    setLaunch(launch);
  }

  void Session::setRestoreLayout(bool enabled) noexcept {
    restore_layout_ = enabled;
  }

  void Session::connected(std::uint64_t identity, bool reads_rows) {
    reads_rows_ = reads_rows;
    panes_.clear();
    tabs_.clear();
    active_tab_.reset();
    left_machine_.reset();
    deferred_tab_.reset();
    features::workbench::clear(workbench_);
    initial_open_pending_ = false;
    workspaces_.resetSource();
    ++view_version_.workspace;
    ++view_version_.tabs;
    ++view_version_.active_tab;
    ++view_version_.panes;
    ready_ = true;
    status_bar_ = {};
    proxy_ = {};
    send(RequestRuntimeState{.client_identity = identity, .interactive = true});
    send(ConfigureGraphics{supportsSharedGraphics()});
    window::pace(*this);
    prompt::configureShell(*this);
  }

  bool Session::requestsPending() const noexcept {
    return pending_count_ != 0;
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
    if (!leave_pending_ || presented_ || (ready_ && pending_count_ != 0)) {
      return false;
    }

    const auto bookmark = machineBookmark();

    if (ready_) {
      workbench::retainLayout(*this);
      for (auto& pane : panes_.viewMut()) {
        if (pane->attached || pane->attaching) {
          prepareDetach(pane->id);
          send(DetachPane{pane->id});
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
    ++view_version_.host;
    ready_ = false;
    features::terminal::graphics::suspend(graphics_);
    agents_.resetSource();
    pane_list_.resetSource();
    workspaces_.resetSource();
    features::terminal::copy_mode::close(copy_mode_);
    features::history::suspend(history_);
    features::paths::close(paths_);
    features::peek::close(peek_);
    features::palette::discard(palette_);
    pending_count_ = 0;
    features::terminal::links::suspend(links_);
    features::prompt::failAll(prompt_);
    for (auto& pane : panes_.viewMut()) {
      pane.getMut().attached = false;
      pane.getMut().attaching = false;
      pane.getMut().snapshot_requested = false;
      pane.getMut().acknowledged_frame = 0;
      pane.getMut().screen.detach();
      pane.getMut().graphics.detach();
      pane.getMut().rows.release();
      pane.getMut().scrollback_generation = 0;
    }

    for (auto& tab : tabs_.viewMut()) {
      tab.getMut().loading = false;
    }
  }

  Change Session::consume(std::span<const Byte> payload) {
    UnsupportedClientCommand handler;

    return consume(payload, handler);
  }

  Change Session::consume(std::span<const Byte> payload, const ClientCommandHandler& handler) {
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

  const Pane<Memory>* Session::findPane(std::uint64_t pane_id) const noexcept {
    const auto found = std::find_if(panes_.begin(), panes_.end(), [&](const auto& pane) {
      return pane->id == pane_id;
    });

    return found == panes_.end() ? nullptr : &found->get();
  }

  Pane<Memory>* Session::findPaneMut(std::uint64_t pane_id) noexcept {
    const auto panes = panes_.viewMut();
    const auto found = std::find_if(panes.begin(), panes.end(), [&](const auto& pane) {
      return pane->id == pane_id;
    });

    return found == panes.end() ? nullptr : &found->getMut();
  }

  const Tab<Memory>* Session::activeTab() const noexcept {
    return active_tab_ ? findTab(*active_tab_) : nullptr;
  }

  Tab<Memory>* Session::activeTabMut() noexcept {
    return active_tab_ ? findTabMut(*active_tab_) : nullptr;
  }

  const Pane<Memory>* Session::focusedPane() const noexcept {
    const auto* tab = activeTab();

    return tab == nullptr ? nullptr : findPane(tab->focused_pane);
  }

  Pane<Memory>* Session::focusedPaneMut() noexcept {
    const auto* tab = activeTab();

    return tab == nullptr ? nullptr : findPaneMut(tab->focused_pane);
  }

  const ds::Vec<ds::Box<Tab<Memory>, Memory>, Memory>& Session::tabs() const noexcept {
    return tabs_;
  }

  const ds::Vec<ds::Box<Pane<Memory>, Memory>, Memory>& Session::panes() const noexcept {
    return panes_;
  }

  const ds::Vec<Workspace<Memory>, Memory>& Session::workspaces() const noexcept {
    return workspaces_.entries();
  }

  const WorkspaceReplica<Memory>& Session::workspaceList() const noexcept {
    return workspaces_;
  }

  const ds::Vec<Agent<Memory>, Memory>& Session::agents() const noexcept {
    return agents_.entries();
  }

  std::uint64_t Session::agentRevision() const noexcept {
    return agents_.revision();
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

  const Configuration& Session::configuration() const noexcept {
    return configuration_;
  }

  ClientViewState Session::clientViewState() const noexcept {
    return {.sidebar_visible = configuration_.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .pane_gaps = configuration_.pane_gaps, .window_title = configuration_.window_title.view()};
  }

  ViewVersion Session::viewVersion() const noexcept {
    return view_version_;
  }

  void Session::invalidateView() noexcept {
    ++view_version_.host;
  }

  void Session::setSidebarVisible(bool visible) {
    if (configuration_.sidebar_visible != visible) {
      ++view_version_.host;
    }

    configuration_.sidebar_visible = visible;
    workbench::retainLayout(*this);
  }

  void Session::setSidebarWidth(float width) {
    if (configuration_.sidebar_width != width) {
      ++view_version_.host;
    }

    configuration_.sidebar_width = width;
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

  std::uint64_t Session::nextRequest() noexcept {
    return ++request_id_;
  }

  std::uint64_t Session::pending(RequestKind kind, std::uint64_t pane_id, ClientLayoutAxis axis) {
    if (pending_count_ == pending_.size()) {
      throw std::length_error{"Pending GUI request capacity reached"};
    }

    const auto request = nextRequest();

    pending_.atMut(pending_count_++) = {.id = request, .kind = kind, .pane_id = pane_id, .axis = axis};

    return request;
  }

  auto Session::complete(std::uint64_t request_id) noexcept -> ds::Option<Pending> {
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
  Change Session::dispatchMessage(std::span<const Byte> payload, DecodeStorage& storage, const ClientCommandHandler& handler) {
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
    transport_.recover(reason);
  }

  Change Session::apply(const SystemMetrics& message) {
    return status_bar::receive(*this, message);
  }

  Change Session::apply(const ProxyStatus& message) {
    proxy_ = message;
    return Change::model;
  }

  Change Session::apply(const RequestFailed& message) {
    for (auto& pane : panes_.viewMut()) {
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

    if (const auto request = complete(message.request_id)) {
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
    const auto request = complete(message.request_id);
    if (request && request->kind == RequestKind::forget_worktree) {
      return Change::none;
    }

    if (request && request->kind == RequestKind::close_pane) {
      ++view_version_.panes;
      for (auto& tab : tabs_.viewMut()) {
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
  template std::span<const Byte> Session::encode<ReportLimit>(const ReportLimit& message);

  template void Session::send<AcknowledgeAgent>(const AcknowledgeAgent& message);
  template void Session::send<ClosePane>(const ClosePane& message);
  template void Session::send<CloseTab>(const CloseTab& message);
  template void Session::send<CompleteClientCommand>(const CompleteClientCommand& message);
  template void Session::send<CompletePaneFocus>(const CompletePaneFocus& message);
  template void Session::send<CompleteWords>(const CompleteWords& message);
  template void Session::send<ConfigureFrameInterval>(const ConfigureFrameInterval& message);
  template void Session::send<ConfigureShellPrompt>(const ConfigureShellPrompt& message);
  template void Session::send<CopySelection>(const CopySelection& message);
  template void Session::send<CreatePane>(const CreatePane& message);
  template void Session::send<CreateTab>(const CreateTab& message);
  template void Session::send<CreateWorkspace>(const CreateWorkspace& message);
  template void Session::send<DeleteHistory>(const DeleteHistory& message);
  template void Session::send<DetachPane>(const DetachPane& message);
  template void Session::send<FindPaths>(const FindPaths& message);
  template void Session::send<ForgetWorktree>(const ForgetWorktree& message);
  template void Session::send<FrameAck>(const FrameAck& message);
  template void Session::send<GraphicsCredit>(const GraphicsCredit& message);
  template void Session::send<InterruptAgent>(const InterruptAgent& message);
  template void Session::send<LaunchWorktree>(const LaunchWorktree& message);
  template void Session::send<MoveTab>(const MoveTab& message);
  template void Session::send<OpenEditor>(const OpenEditor& message);
  template void Session::send<OpenPane>(const OpenPane& message);
  template void Session::send<PaneCommand>(const PaneCommand& message);
  template void Session::send<PaneInput>(const PaneInput& message);
  template void Session::send<PaneResize>(const PaneResize& message);
  template void Session::send<QueryHistory>(const QueryHistory& message);
  template void Session::send<ReadHistoryOutput>(const ReadHistoryOutput& message);
  template void Session::send<ReadPane>(const ReadPane& message);
  template void Session::send<ReadPaneRows>(const ReadPaneRows& message);
  template void Session::send<RenameTab>(const RenameTab& message);
  template void Session::send<RenameWorkspace>(const RenameWorkspace& message);
  template void Session::send<RequestCommandSpec>(const RequestCommandSpec& message);
  template void Session::send<RequestGraphicsSnapshot>(const RequestGraphicsSnapshot& message);
  template void Session::send<RequestSnapshot>(const RequestSnapshot& message);
  template void Session::send<RequestTabSnapshot>(const RequestTabSnapshot& message);
  template void Session::send<RequestWorkspaceSnapshot>(const RequestWorkspaceSnapshot& message);
  template void Session::send<SearchPane>(const SearchPane& message);
  template void Session::send<SearchPaneRows>(const SearchPaneRows& message);
  template void Session::send<SendPaneText>(const SendPaneText& message);
  template void Session::send<SetPaneViewport>(const SetPaneViewport& message);
  template void Session::send<SuggestCommand>(const SuggestCommand& message);
  template void Session::send<UpdateClientLayout>(const UpdateClientLayout& message);

}
