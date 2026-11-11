module;
#include "tbc/view.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>

export module telar.gui.application.session;

import std;

export import telar.gui.application.host_effects;
export import telar.gui.application.workspace_replica;
export import telar.gui.core.metrics;
export import telar.gui.core.unicode_scalar;
export import telar.gui.graphics.texture_cache;
export import telar.gui.graphics.pauses;
export import telar.gui.history.browser;
export import telar.gui.input.copy_pointer;
export import telar.gui.input.configuration;
export import telar.gui.input.key_encoder;
export import telar.gui.input.child_mouse;
export import telar.gui.application.sound_playback;
export import telar.gui.links.path_expansion;
export import telar.gui.links.cell_links;
export import telar.gui.paths.label;
export import telar.gui.peek.screen;
export import telar.gui.platform.profile_file;
export import telar.gui.presentation.notification_stack;
export import telar.gui.presentation.activity_order;
export import telar.gui.presentation.frame_pacer;
export import telar.gui.presentation.display_metrics;
export import telar.gui.presentation.application_mark;
export import telar.gui.suggestions.state;
export import telar.config;
export import telar.platform;
export import telar.gui.terminal.font_grid;
export import telar.gui.terminal.copy_mode;
export import telar.gui.prompt.island;
export import telar.gui.prompt.layout;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: application/session.cppm
export {
namespace telar::gui {

template <typename Transport>
concept RuntimeTransport = requires(Transport &transport, const PaneInput &input, const FrameAck &ack) {
  transport.send(input);
  transport.send(ack);
};

enum class Change : std::uint8_t {
  none,
  model,
  configuration,
  terminal,
  clipboard,
  history,
  notification,
  metrics,
  stopped,
  closed,
  copy_mode,
  paths,
  suggestion,
  peek,
};

// Whether the shell runs a command word: asked of the runtime, pending until it answers,
// unknown where it cannot tell (a remote shell, names it never reported).
enum class CommandPresence : std::uint8_t {
  unknown,
  pending,
  found,
  missing,
};

template <Allocator Memory, RuntimeTransport Transport, MonotonicClock Clock = platform::AwakeClock, HostEffects Effects = DiscardHostEffects>
class Session {
public:
  static constexpr std::size_t decode_capacity = std::size_t{2} * 1024 * 1024;
  static constexpr std::size_t maximum_workspaces = 128;
  static constexpr std::size_t maximum_tabs = 256;
  static constexpr std::size_t maximum_workspace_tabs = 64;
  static constexpr std::size_t maximum_panes = maximum_tabs * PaneLayout::maximum_panes;
  static constexpr std::size_t maximum_pending = 256;
  static constexpr std::size_t maximum_retained_layout_nodes = 511;
  static constexpr std::size_t input_chunk_size = 65536;
  // A viewport past any bottom: the runtime follows the output.
  static constexpr std::uint32_t follow_output = std::numeric_limits<std::uint32_t>::max();
  static constexpr std::uint16_t history_page_size = HistoryBrowser<Memory>::page_entries;
  static constexpr std::size_t maximum_history_query_bytes = HistoryBrowser<Memory>::maximum_query_bytes;
  static constexpr std::uint16_t default_sidebar_columns = SidebarColumns::minimum_width;
  static constexpr std::size_t maximum_launch_arguments = 64;

  // The session keeps the allocator and the transport, region `a`, which also holds what its replies and
  // requests view of the session's own panes, workspaces and responses.
  inline Session(tbc::view<Memory &, tbc::lt::a> memory, tbc::view<Transport &, tbc::lt::a> transport, Effects effects = {})
      : memory_(memory),
        transport_(transport),
        effects_(std::move(effects)),
        panes_(AllocatorRef<Owned<Pane<Memory>, Memory>, Memory>{memory}),
        tabs_(AllocatorRef<Owned<Tab<Memory>, Memory>, Memory>{memory}),
        workspaces_(memory),
        agents_(memory),
        pane_list_(memory),
        history_(memory),
        peek_(memory),
        decode_(AllocatorRef<Byte, Memory>{memory}),
        clipboard_(AllocatorRef<char, Memory>{memory}),
        notice_(AllocatorRef<char, Memory>{memory}),
        error_(AllocatorRef<char, Memory>{memory}),
        command_response_(AllocatorRef<char, Memory>{memory}),
        launch_cwd_(AllocatorRef<char, Memory>{memory}),
        argument_storage_(AllocatorRef<String<Memory>, Memory>{memory}) {
    decode_.resize(decode_capacity);
  }

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  inline void setLaunch(const Launch &launch) {
    BodySchema<Launch>::validate(launch);
    launch_cwd_ = launch.cwd;
    argument_storage_.clear();
    launch_argument_count_ = 0;
    argument_storage_.reserve(launch.arguments.size());
    for (const auto argument : launch.arguments) {
      argument_storage_.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
    }

    for (const auto &argument : argument_storage_) {
      launch_arguments_[launch_argument_count_++] = argument;
    }
  }

  inline void setLaunchDirectory(std::string_view directory) {
    auto launch = defaultLaunch();
    launch.cwd = directory;
    BodySchema<Launch>::validate(launch);
    launch_cwd_ = directory;
  }

  inline void setLaunchArguments(std::span<const std::string_view> arguments) {
    auto launch = defaultLaunch();
    launch.arguments = arguments;
    setLaunch(launch);
  }

  inline void setRestoreLayout(bool enabled) noexcept {
    restore_layout_ = enabled;
  }

  // `reads_rows`: the runtime reads its scrollback's rows by stable number (schema cqp00003).
  inline void connected(std::uint64_t identity, bool reads_rows = true) {
    reads_rows_ = reads_rows;
    panes_.clear();
    tabs_.clear();
    active_tab_.reset();
    left_machine_.reset();
    deferred_tab_.reset();
    pending_layout_restore_.reset();
    navigation_history_.clear();
    saved_layouts_.clear();
    initial_open_pending_ = false;
    workspaces_.resetSource();
    ++view_version_.workspace;
    ++view_version_.tabs;
    ++view_version_.active_tab;
    ++view_version_.panes;
    ready_ = true;
    metrics_ = {};
    proxy_ = {};
    transport_.send(RequestRuntimeState{.client_identity = identity, .interactive = true});
    transport_.send(ConfigureGraphics{supportsSharedGraphics()});
    configureCadence();
    configureShellPrompt();
  }

  [[nodiscard]] inline bool requestsPending() const noexcept {
    return pending_count_ != 0;
  }

  [[nodiscard]] inline bool presented() const noexcept {
    return presented_;
  }

  inline void setPresented(bool presented) {
    if (presented_ == presented) {
      if (!presented) {
        static_cast<void>(settlePresentation());
      }

      return;
    }

    presented_ = presented;
    leave_pending_ = !presented;
    if (!presented) {
      closePeek();
    }

    if (presented) {
      if (ready_) {
        restoreMachinePresentation();
      }
    } else {
      static_cast<void>(settlePresentation());
    }
  }

  inline bool settlePresentation() {
    if (!leave_pending_ || presented_ || (ready_ && pending_count_ != 0)) {
      return false;
    }

    const auto bookmark = machineBookmark();
    if (ready_) {
      retainLayout();
      for (auto &pane : panes_) {
        if (pane->attached || pane->attaching) {
          prepareDetach(pane->id);
          transport_.send(DetachPane{pane->id});
          pane->attached = false;
          pane->attaching = false;
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

  inline void disconnected() noexcept {
    ++view_version_.host;
    ready_ = false;
    graphics_pauses_.reset();
    agents_.resetSource();
    pane_list_.resetSource();
    workspaces_.resetSource();
    copy_mode_.reset();
    copy_search_request_ = 0;
    history_.suspend();
    path_picker_.close();
    peek_.close();
    suggestion_.invalidate();
    pending_count_ = 0;
    editor_opening_.reset();
    for (auto &pane : panes_) {
      pane->attached = false;
      pane->attaching = false;
      pane->snapshot_requested = false;
      pane->acknowledged_frame = 0;
      pane->screen.detach();
      pane->graphics.detach();
      pane->rows.release();
      pane->scrollback_generation = 0;
    }

    for (auto &tab : tabs_) {
      tab->loading = false;
    }
  }

  inline Change consume(std::span<const Byte> payload) {
    UnsupportedClientCommand handler;

    return consume(payload, handler);
  }

  template <ClientCommandHandler Handler>
  inline Change consume(std::span<const Byte> payload, Handler &handler) {
    if (payload.empty()) {
      throw EncodingError{"Empty server message"};
    }

    DecodeStorage storage{decode_};
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

  inline void selectTab(TabLocation location) {
    if (!active_tab_ || !sameTab(*active_tab_, location)) {
      ++view_version_.active_tab;
      if (!active_tab_ || !sameWorkspace(active_tab_->workspace, location.workspace)) {
        ++view_version_.workspace;
      }
    }

    if (const auto *copy_pane = copyPane(); copy_pane != nullptr && !sameTab(copy_pane->location, location)) {
      copy_mode_.reset();
      copy_search_request_ = 0;
    }

    active_tab_ = location;
    auto &tab = ensureTab(location);
    for (const auto &candidate : tabs_) {
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

  inline bool selectWorkspace(WorkspaceLocation location) {
    if (!ready_ || workspaces_.revision() == 0 || requestsPending() || location.kind != WorkspaceLocation::Kind::workspace || workspaces_.indexOf(location.id) == workspaces_.entries().size() || (active_tab_ && sameWorkspace(active_tab_->workspace, location))) {
      return false;
    }

    const auto *bookmark = navigation_history_.find(location);
    const auto target = bookmark != nullptr ? PaneTarget{.kind = PaneTarget::Kind::pane, .id = bookmark->pane_id} : PaneTarget{.kind = PaneTarget::Kind::workspace, .id = location.id};
    handoffWorkspace(target, location.id);

    return true;
  }

  inline void selectWorkspaceIndex(std::size_t index) {
    const auto projects = workspaces_.projects();
    if (index < projects.size()) {
      static_cast<void>(selectWorkspace(projects[index].location));
    }
  }

  inline void focusPane(std::uint64_t pane_id) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr) {
      const auto agent = std::find_if(agents_.begin(), agents_.end(), [&](const auto &entry) {
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

    auto &tab = ensureTab(pane->location);
    setPaneFocus(tab, pane_id);
    selectTab(pane->location);
    synchronizeAttachments();
    retainLayout();
  }

  inline bool openWorktree(std::uint64_t identity) {
    const auto *row = workspaces_.worktree(identity);
    if (!ready_ || row == nullptr || !row->workspace) {
      return false;
    }

    const auto workspace = *row->workspace;
    return selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = workspace});
  }

  inline bool leaveWorktree() {
    if (!ready_ || !active_tab_ || active_tab_->workspace.kind != WorkspaceLocation::Kind::workspace) {
      return false;
    }

    const auto *row = workspaces_.worktreeOfWorkspace(active_tab_->workspace.id);
    if (row == nullptr) {
      return false;
    }

    const auto source = row->source;
    return selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = source});
  }

  inline std::size_t forgetGoneWorktrees() {
    if (!ready_) {
      return 0;
    }

    std::size_t sent = 0;
    for (const auto &row : workspaces_.worktrees()) {
      if (row.state != WorktreeState::gone || row.workspace) {
        continue;
      }

      if (pending_count_ == pending_.size()) {
        break;
      }

      const auto request_id = pending(RequestKind::forget_worktree);
      try {
        transport_.send(ForgetWorktree{.request_id = request_id, .worktree = row.id});
      } catch (...) {
        complete(request_id);
        throw;
      }

      ++sent;
    }

    return sent;
  }

  inline TabCreationOutcome createTab(std::string_view label = {}) {
    return requestTabCreation(label, {});
  }

  inline TabCreationOutcome createCommandTab(const runtime::config::CommandTabView &command) {
    if (command.count == 0 || command.count > command.arguments.size()) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    return requestTabCreation(command.label(), command.argv());
  }

  // Without a directory the workspace starts where the focused pane is.
  inline void createWorkspace(WorkspaceDraft draft) {
    auto launch = defaultLaunch();
    if (!draft.path.empty()) {
      launch.cwd = draft.path;
    } else if (const auto *pane = focusedPane(); pane != nullptr) {
      launch.cwd_source = pane->id;
    }

    sendOpeningRequest(RequestKind::create_workspace, CreateWorkspace{.size = launchSize(), .name = draft.name, .create_cwd = draft.create_directory, .launch = launch});
  }

  template <PathEnvironment Environment>
  inline void openFile(const FilePath &path, std::string_view executable, const Environment &environment, std::optional<std::uint64_t> source_id = {}) {
    if (executable.empty()) {
      throw std::runtime_error{"EditorUnavailable"};
    }

    if (!source_id) {
      if (!path.text().starts_with('/')) {
        throw std::invalid_argument{"RelativeFileLink"};
      }

      createEditorTab(EditorTarget{executable, path.text(), path.line(), path.column()});

      return;
    }

    const auto *source = findPane(*source_id);
    if (source == nullptr || !active_tab_ || !sameTab(source->location, *active_tab_)) {
      throw std::runtime_error{"PaneNotFound"};
    }

    const auto anchored = path.text().starts_with('/') ? PathExpansion::PathText{} : PathExpansion::expand({.text = path.text(), .base = source->cwd}, environment);
    const EditorRequest request{
        .request_id = source->generation == 0 ? 0 : nextRequest(),
        .source = {.pane_id = source->id, .pane_generation = source->generation, .attachment_generation = source->attachment_generation, .location = source->location},
        .target = EditorTarget{executable, path.text().starts_with('/') ? path.text() : anchored.view(), path.line(), path.column()},
    };
    if (source->generation == 0) {
      splitEditorPane(request);

      return;
    }

    editor_opening_.begin(request);
    try {
      transport_.send(request.message());
    } catch (...) {
      static_cast<void>(editor_opening_.complete(request.request_id));
      throw;
    }
  }

  inline void setWorkbenchGeometry(WorkbenchGeometry geometry) noexcept {
    if (workbench_geometry_ != geometry) {
      workbench_geometry_ = geometry;
      ++view_version_.viewport;
    }
  }

  inline void setAttachmentReservation(std::optional<PaneBottomReservation> reservation) {
    if (attachment_reservation_ != reservation) {
      attachment_reservation_ = reservation;
      attachment_resize_pending_ = true;
      for (auto &tab : tabs_) {
        tab->layout.setBottomReservation(reservation);
      }

      ++view_version_.viewport;
    }

    if (attachment_resize_pending_) {
      if (auto *tab = activeTab()) {
        resizeVisiblePanes(*tab);
      }

      attachment_resize_pending_ = false;
    }
  }

  [[nodiscard]] inline const WorkbenchGeometry &workbenchGeometry() const noexcept {
    return workbench_geometry_;
  }

  inline bool split(ClientLayoutAxis axis) {
    const auto *tab = activeTab();
    if (tab == nullptr) {
      return false;
    }

    return requestPaneSplit(tab->focused_pane, axis, defaultLaunch());
  }

  inline bool closePane(std::uint64_t pane_id) {
    if (hasPaneOperation()) {
      return false;
    }

    const auto request_id = pending(RequestKind::close_pane, pane_id);
    try {
      transport_.send(ClosePane{request_id, pane_id});
    } catch (...) {
      complete(request_id);
      throw;
    }

    return true;
  }

  inline void closeTab(TabLocation location) {
    if (!hasTabOperation()) {
      sendTabOperation(RequestKind::close_tab, CloseTab{.location = location});
    }
  }

  inline void renameTab(std::string_view label) {
    if (const auto location = active_tab_; location && !hasTabOperation()) {
      sendTabOperation(RequestKind::rename_tab, RenameTab{.location = *location, .label = label});
    }
  }

  inline void selectTabIndex(std::size_t index) {
    std::array<Tab<Memory> *, maximum_tabs> ordered{};
    const auto count = orderedTabs(ordered);
    if (index < count) {
      selectTab(ordered[index]->location);
    }
  }

  inline void selectTabOffset(std::int32_t offset) {
    std::array<Tab<Memory> *, maximum_tabs> ordered{};
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

  inline void moveTab(TabMoveDirection direction, std::optional<std::uint64_t> relative_to = {}) {
    if (const auto location = active_tab_) {
      static_cast<void>(requestTabMove({.location = *location, .direction = direction, .relative_to = relative_to}));
    }
  }

  [[nodiscard]] inline bool tabOperationPending() const noexcept { return hasTabOperation(); }

  [[nodiscard]] inline bool requestTabMove(const TabDragMove &move) {
    if (hasTabOperation() || !active_tab_ || !sameWorkspace(active_tab_->workspace, move.location.workspace) || findTab(move.location) == nullptr) {
      return false;
    }

    if (move.relative_to && (*move.relative_to == move.location.tab_id || findTab({.workspace = move.location.workspace, .tab_id = *move.relative_to}) == nullptr)) {
      return false;
    }

    sendTabOperation(RequestKind::move_tab, MoveTab{.location = move.location, .direction = move.direction, .relative_to = move.relative_to});

    return true;
  }

  inline void focusDirection(PaneDirection direction) {
    if (const auto neighbor = neighboringPane(direction); neighbor != 0) {
      focusPane(neighbor);
    }
  }

  inline void navigateDirection(PaneDirection direction) {
    const auto *pane = focusedPane();
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
    const auto *const found = std::ranges::find(characters, direction, &decltype(characters)::value_type::first);
    if (found == characters.end()) {
      return;
    }

    const TerminalKey key{.codepoint = static_cast<std::uint32_t>(found->second), .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
    KeyEncoder encoder;
    input(pane->id, encoder.encode(key, pane->screen.modes()));
  }

  inline bool resizeDirection(PaneDirection direction) {
    auto *tab = activeTab();
    if (tab == nullptr || tab->fullscreen || !tab->layout.resize(tab->focused_pane, direction, workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics)) {
      return false;
    }

    ++view_version_.panes;
    retainLayout();

    return true;
  }

  inline void renameWorkspace(std::string_view name) {
    if (const auto location = active_tab_) {
      transport_.send(RenameWorkspace{nextRequest(), location->workspace, name});
    }
  }

  inline void input(std::uint64_t pane_id, std::string_view bytes, PaneInputSource source = PaneInputSource::keyboard) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited || bytes.empty()) {
      return;
    }

    if (source == PaneInputSource::keyboard && promptSurface(pane_id) == prompt::Surface::secret) {
      const auto byte = static_cast<unsigned char>(bytes.front());
      auto &island = islandEntry(pane_id).island;
      if (byte == 0x7f || byte == 0x08 || byte == 0x15) {
        island.clearSecret();
      } else if (byte >= 0x20) {
        island.countSecretKey();
      }
    }

    if (source == PaneInputSource::keyboard || source == PaneInputSource::key_release) {
      static_cast<void>(copy_mode_.clearPointer());
      if (source != PaneInputSource::key_release) {
        followLiveEnd(*pane);
      }
    }

    auto pending_bytes = byteView(bytes);
    while (!pending_bytes.empty()) {
      const auto count = std::min(pending_bytes.size(), input_chunk_size);
      transport_.send(PaneInput{.pane_id = pane_id, .bytes = pending_bytes.first(count)});
      if (source != PaneInputSource::terminal_report && pending_bytes.size() == bytes.size()) {
        notePaneInput(*pane);
      }

      pending_bytes = pending_bytes.subspan(count);
    }
  }

  // Runs a command at the pane's prompt. A runtime that takes commands types it there itself and
  // keeps this text for the command's history; an older one (schema cqp00002) gets it pasted,
  // then Enter, and reads the command back from the screen.
  inline void runCommand(std::uint64_t pane_id, std::string_view text) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited || text.empty()) {
      return;
    }

    if (!reads_rows_) {
      pasteBytes(pane_id, text);
      input(pane_id, "\r");
      return;
    }

    static_cast<void>(copy_mode_.clearPointer());
    followLiveEnd(*pane);
    transport_.send(PaneCommand{.pane_id = pane_id, .text = byteView(text)});
    notePaneInput(*pane);
  }

  // Typing returns a scrolled pane to its live end, where the output follows.
  inline void followLiveEnd(Pane<Memory> &pane) {
    const auto bottom = copyGrid(pane.screen).maximumOffset();
    if (pane.screen.scroll().offset != bottom) {
      ++view_version_.viewport;
      ++pane.viewport_requests;
      pane.screen.setViewport(bottom);
      transport_.send(SetPaneViewport{.pane_id = pane.id, .offset = follow_output});
    }
  }

  inline void notePaneInput(const Pane<Memory> &pane) {
    if constexpr (PaneInputObserver<Effects>) {
      effects_.notePaneInput({.pane_id = pane.id, .frame_id = pane.screen.frameId(), .attached = pane.attached, .attachment_generation = pane.attachment_generation, .graphics_revision = pane.graphics.revision()}, Clock::nowNanoseconds());
    }
  }

  // ---- telar's command editor -----------------------------------------------------------

  [[nodiscard]] inline prompt::Surface promptSurface(std::uint64_t pane_id) const noexcept {
    const auto *pane = findPane(pane_id);
    // telar's editor stays while copy mode, which owns the keys, reads the scrollback.
    if (pane == nullptr || !pane->attached || pane->exited || (copy_mode_.active() && configuration_.prompt.mode != PromptMode::telar)) {
      return prompt::Surface::none;
    }
    return prompt::surface(pane->shell, pane->screen.modes().alternate_screen, configuration_.prompt.mode == PromptMode::telar);
  }

  // ---- scrollback rows beyond the screen ----------------------------------------------------

  // Whether the runtime sends rows of a scrollback apart from its screen, for a view that
  // scrolls by pixels or folds commands. Without them the view moves by whole rows.
  [[nodiscard]] inline bool readsRows() const noexcept {
    return reads_rows_ && ready_;
  }

  // Asks for the rows from stable row `first` to `last` the pane holds neither on its screen
  // nor in its cache, a request at a time while requests are free.
  inline void requestRows(std::uint64_t pane_id, std::uint64_t first, std::uint64_t last) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || !pane->attached || !readsRows() || pane->scrollback_generation == 0 || last < first) {
      return;
    }
    const auto screen_first = pane->scrollback_trimmed + pane->screen.cellsOffset();
    const auto screen_last = screen_first + pane->screen.rows();
    auto from = first;
    while (!pane->rows.full()) {
      const auto missing = pane->rows.missing(from, last);
      if (!missing) {
        return;
      }
      // Rows on the screen come in its frames.
      if (*missing >= screen_first && *missing < screen_last) {
        from = screen_last;
        continue;
      }
      const auto count = static_cast<std::uint16_t>(std::min<std::uint64_t>(RowCache<Memory>::request_rows, last - *missing + 1));
      const auto request_id = nextRequest();
      transport_.send(ReadPaneRows{.request_id = request_id, .pane_id = pane_id, .from = *missing, .count = count});
      pane->rows.ask(request_id, *missing, count);
      from = *missing + count;
    }
  }

  // The rows the scrollback dropped from its top since the pane's view last asked: the view
  // moves up by as many to keep showing the same rows.
  [[nodiscard]] inline std::uint64_t takeDroppedRows(std::uint64_t pane_id) noexcept {
    auto *pane = findPane(pane_id);
    return pane == nullptr ? 0 : std::exchange(pane->scrollback_dropped, 0);
  }

  // ---- folded commands ------------------------------------------------------------------------

  // The stable number of a block's first row, which names it while rows above it are dropped.
  [[nodiscard]] inline static std::uint64_t blockKey(const Pane<Memory> &pane, std::size_t index) noexcept {
    return pane.scrollback_trimmed + pane.blocks[index].row;
  }

  [[nodiscard]] inline bool folded(std::uint64_t pane_id, std::size_t index) const noexcept {
    const auto *pane = findPane(pane_id);
    return pane != nullptr && index < pane->blocks.size() && std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end();
  }

  // Folds the output of block `index`, or unfolds it. Only a runtime that sends rows apart from
  // the screen can show what follows a fold.
  inline void fold(std::uint64_t pane_id, std::size_t index, bool fold) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || index >= pane->blocks.size() || (fold && !readsRows())) {
      return;
    }
    const auto key = blockKey(*pane, index);
    const auto found = std::ranges::find(pane->folded, key);
    if (fold == (found != pane->folded.end())) {
      return;
    }
    if (fold) {
      pane->folded.push_back(key);
    } else {
      pane->folded.erase(found);
    }
    refreshFolds(*pane);
    changed_pane_ = pane_id;
    fold_changed_ = true;
  }

  // Folds every block but a running one, or unfolds them all.
  inline void foldAll(std::uint64_t pane_id, bool fold) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || (fold && !readsRows())) {
      return;
    }
    pane->folded.clear();
    for (std::size_t index = 0; fold && index < pane->blocks.size(); ++index) {
      if (pane->blocks[index].state != CommandBlockState::running) {
        pane->folded.push_back(blockKey(*pane, index));
      }
    }
    refreshFolds(*pane);
    changed_pane_ = pane_id;
    fold_changed_ = true;
  }

  // Whether a fold opened or closed since the last call.
  [[nodiscard]] inline bool takeFoldChange() noexcept {
    return std::exchange(fold_changed_, false);
  }

  // The rows of block `index`'s output, from under its prompt to above the next prompt, or to
  // the live prompt or the scrollback's end for the last; empty when it printed nothing.
  [[nodiscard]] inline static std::pair<std::uint32_t, std::uint32_t> blockRows(const Pane<Memory> &pane, std::size_t index) noexcept {
    const auto &block = pane.blocks[index];
    const auto first = block.row + block.rows;
    std::uint32_t end = pane.screen.scroll().total_rows;
    if (index + 1 < pane.blocks.size()) {
      end = pane.blocks[index + 1].row;
    } else if (block.state != CommandBlockState::running) {
      // The live prompt, read where the view shows it and remembered while it does not.
      const auto prompt = livePromptRow(pane);
      if (prompt && *prompt >= first) {
        end = *prompt;
      } else if (pane.live_prompt_row && *pane.live_prompt_row >= first) {
        end = *pane.live_prompt_row;
      }
    }
    return {first, std::max(first, end)};
  }

  // ---- command blocks, selected from the editor -------------------------------------------

  [[nodiscard]] inline std::optional<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept {
    const auto found = islands_.find(pane_id);
    const auto *pane = findPane(pane_id);
    if (found == islands_.end() || pane == nullptr || !found->second.block || *found->second.block >= pane->blocks.size()) {
      return std::nullopt;
    }
    return found->second.block;
  }

  // Selects the block at `index`, shown from the top of the pane, or none: the pane's live end.
  inline void selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index) {
    const auto *pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }
    auto &entry = islandEntry(pane_id);
    entry.pending = 0;
    if (index && *index < pane->blocks.size()) {
      if (!entry.block) {
        entry.live_prompt = livePromptRow(*pane);
      }
      entry.block = index;
      const auto row = pane->blocks[*index].row;
      scrollToRow(pane_id, row == 0 ? 0 : row - 1);
    } else {
      entry.block.reset();
      scrollToRow(pane_id, std::numeric_limits<std::uint32_t>::max());
    }
    changed_pane_ = pane_id;
    block_changed_ = true;
  }

  // prefix+[ where telar's editor stands in for the prompt: the last command block, selected,
  // instead of copy mode from the live end.
  inline bool enterBlocks() {
    const auto *pane = focusedPane();
    if (pane == nullptr || configuration_.prompt.mode != PromptMode::telar || pane->blocks.empty() || promptSurface(pane->id) != prompt::Surface::editor || selectedBlock(pane->id)) {
      return false;
    }
    selectBlock(pane->id, pane->blocks.size() - 1);
    return true;
  }

  // The pane whose editor took text from outside the keyboard (a paste, a history entry, a
  // suggestion, a path) since the last call, for its view to show it.
  [[nodiscard]] inline std::optional<std::uint64_t> takePromptWrite() noexcept {
    const auto written = std::exchange(prompt_written_, 0);
    return written == 0 ? std::nullopt : std::optional{written};
  }

  // Whether a block was selected or left, or copy mode began on one, since the last call.
  [[nodiscard]] inline bool takeBlockChange() noexcept {
    return std::exchange(block_changed_, false);
  }

  // Whether text was written to the clipboard since the last call, as copying a command does.
  [[nodiscard]] inline bool takeClipboardWrite() noexcept {
    return std::exchange(clipboard_written_, false);
  }

  // Whether text meant for the pane belongs in telar's editor instead.
  [[nodiscard]] inline bool editsPrompt(std::uint64_t pane_id) const noexcept {
    const auto surface = promptSurface(pane_id);
    return surface == prompt::Surface::editor || surface == prompt::Surface::running;
  }

  [[nodiscard]] inline std::span<const std::string> promptHistory() const noexcept {
    return prompt_history_;
  }

  [[nodiscard]] inline const prompt::Island *island(std::uint64_t pane_id) const noexcept {
    const auto found = islands_.find(pane_id);
    return found == islands_.end() ? nullptr : &found->second.island;
  }

  // A key for the pane's editor or queue. `terminal` hands it back to the terminal.
  inline prompt::Outcome promptKey(std::uint64_t pane_id, const prompt::KeyPress &key) {
    const auto surface = promptSurface(pane_id);
    if (surface != prompt::Surface::editor && surface != prompt::Surface::running) {
      return prompt::Outcome::terminal;
    }

    auto &entry = islandEntry(pane_id);
    if (surface == prompt::Surface::editor) {
      if (const auto outcome = blockKey(pane_id, entry, key)) {
        return *outcome;
      }
    }
    if (surface == prompt::Surface::running && !entry.island.answering()) {
      const auto *pane = findPane(pane_id);
      // Signal and end-of-file keys always reach the program, as does typing while it seems
      // to ask a question.
      if (key.key == prompt::Key::character && key.modifiers.control && !key.modifiers.alt && key.character < 0x80) {
        const char control = static_cast<char>(key.character & 0x1f);
        if (prompt::controlKey(pane->shell, {&control, 1})) {
          return prompt::Outcome::terminal;
        }
      }
      if (entry.island.editor().text().empty() && prompt::PendingPrompt::likely(pane->screen.cursor().x, std::chrono::nanoseconds{Clock::nowNanoseconds() - entry.output})) {
        return prompt::Outcome::terminal;
      }
    }

    const auto syntax = shell::Syntax{.dialect = findPane(pane_id)->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix};
    const auto incomplete = [syntax](std::string_view text) { return prompt::incomplete(text, syntax); };
    const auto bound = boundAction(key, entry.island.editor());
    const auto outcome = bound ? entry.island.perform(surface, *bound, incomplete, prompt_history_) : entry.island.press(surface, key, incomplete, prompt_history_);
    if (outcome == prompt::Outcome::complete) {
      beginCompletion(pane_id, entry.island, syntax);
      return prompt::Outcome::edited;
    }
    deliverPrompt(pane_id, outcome, entry.island);
    return outcome;
  }

  // Whether the pane's shell runs `word`, for the editor to mark a command that does not
  // exist. Asks the runtime the first time and answers pending until it replies; a remote
  // shell's commands are unknown. Forgotten after each command and change of directory.
  inline CommandPresence commandPresence(std::uint64_t pane_id, std::string_view word) {
    const auto *pane = findPane(pane_id);
    if (pane == nullptr || pane->shell.remote || !ready_ || word.empty() || word.size() > 256) {
      return CommandPresence::unknown;
    }
    auto &checks = commandChecks(*pane);
    if (checks.learned.contains(word)) {
      return CommandPresence::found;
    }
    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      return known->second;
    }

    const auto request_id = nextRequest();
    try {
      const auto slash = word.rfind('/');
      if (slash == std::string_view::npos) {
        transport_.send(CompleteWords{.request_id = request_id, .pane_id = pane_id, .provider = CompletionProvider::command, .prefix = word});
      } else {
        // A command named by its path: a file there, from the directory the shell is in.
        std::string root{word.starts_with('/') ? std::string_view{} : std::string_view{pane->cwd}};
        if (!word.starts_with('/')) {
          root.push_back('/');
        }
        root.append(word.substr(0, slash));
        while (root.size() > 1 && root.ends_with('/')) {
          root.pop_back();
        }
        const auto name = word.substr(slash + 1);
        if (name.empty() || name.size() > 64 || !root.starts_with('/')) {
          return CommandPresence::unknown;
        }
        transport_.send(FindPaths{.request_id = request_id, .root = root, .query = name, .kind = PathKindFilter::any, .limit = 50});
      }
    } catch (const std::exception &) {
      checks.words.emplace(std::string{word}, CommandPresence::unknown);
      return CommandPresence::unknown;
    }
    checks.words.emplace(std::string{word}, CommandPresence::pending);
    command_requests_.emplace(request_id, CommandRequest{pane_id, std::string{word}});
    return CommandPresence::pending;
  }

  // Whether a pane's header changed with its shell's state since the last call.
  [[nodiscard]] inline bool takeChromeChange() noexcept {
    return std::exchange(chrome_changed_, false);
  }

  // Scrolls the pane so `row`, counted from the top of its scrollback, is the first shown.
  inline void scrollToRow(std::uint64_t pane_id, std::uint32_t row) {
    const auto *pane = findPane(pane_id);
    if (pane != nullptr) {
      scroll(PaneScrollDelta{.pane_id = pane_id, .rows = static_cast<std::int64_t>(pane->screen.scroll().offset) - static_cast<std::int64_t>(row)});
    }
  }

  // Text an input method committed or a paste, into the editor. Controls other than newline
  // and tab are dropped: they would act on the shell instead of being written.
  inline void promptText(std::uint64_t pane_id, std::string_view text) {
    std::string clean;
    clean.reserve(text.size());
    for (const auto byte : text) {
      const auto value = static_cast<unsigned char>(byte);
      if (value >= 0x20 || byte == '\n' || byte == '\t') {
        clean.push_back(value == 0x7f ? ' ' : byte);
      }
    }
    islandEntry(pane_id).island.insertText(clean);
    prompt_written_ = pane_id;
  }

  inline void paste(std::uint64_t pane_id, std::string_view bytes) {
    if (copy_mode_.active()) {
      return;
    }

    if (editsPrompt(pane_id)) {
      promptText(pane_id, bytes);
      return;
    }

    pasteBytes(pane_id, bytes);
  }

  // A paste straight to the terminal, framed when the program asked for bracketed paste.
  inline void pasteBytes(std::uint64_t pane_id, std::string_view bytes) {

    const auto *pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    if (pane->screen.modes().bracketed_paste) {
      input(pane_id, PasteEncoding::begin);
    }

    input(pane_id, bytes);

    if (pane->screen.modes().bracketed_paste) {
      input(pane_id, PasteEncoding::end);
    }
  }

  inline void pasteHistory(std::uint64_t entry_id, bool alternate = false) {
    // The entry is copied out of the history, which pasting must not be able to reach.
    const String<Memory> entry{history_.command(entry_id), AllocatorRef<char, Memory>{memory_}};
    const std::string_view command = entry;
    const auto *pane = focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      throw EncodingError{"No terminal is ready for input"};
    }

    if (editsPrompt(pane->id)) {
      auto &text = islandEntry(pane->id).island.editor().text();
      text.assign(command);
      text.moveTo(text.size());
      prompt_written_ = pane->id;
      if (configuration_.history.enter_runs != alternate) {
        promptKey(pane->id, prompt::KeyPress{prompt::Key::enter});
      }
      return;
    }

    HistoryText::validate(command, pane->screen.modes().bracketed_paste);
    paste(pane->id, command);
    if (configuration_.history.enter_runs != alternate) {
      input(pane->id, "\r");
    }
  }

  inline void copyHistory(std::uint64_t entry_id) {
    clipboard_ = history_.command(entry_id);
  }

  inline void beginSuggestion() noexcept {
    suggestion_.begin();
  }

  inline void invalidateSuggestion() noexcept {
    suggestion_.invalidate();
  }

  [[nodiscard]] inline const SuggestionState &suggestion() const noexcept {
    return suggestion_;
  }

  inline bool submitSuggestion(std::string_view text) {
    const auto *pane = focusedPane();
    if (suggestion_.phase() == SuggestionPhase::ready) {
      if (!ready_ || pane == nullptr || !pane->attached || pane->exited || copy_mode_.active()) {
        return false;
      }

      if (editsPrompt(pane->id)) {
        promptText(pane->id, suggestion_.text());
        return true;
      }

      const auto bracketed = pane->screen.modes().bracketed_paste;
      HistoryText::validate(suggestion_.text(), bracketed);
      const auto encoded = PasteEncoding::encode<SuggestionLimits::text_bytes>(suggestion_.text(), bracketed);
      input(pane->id, encoded.view());

      return true;
    }

    if (text.empty() || suggestion_.phase() == SuggestionPhase::waiting) {
      return false;
    }

    if (!ready_ || pane == nullptr || !pane->attached || pane->exited) {
      constexpr std::uint64_t failed_request = 1;
      suggestion_.expect(failed_request);
      static_cast<void>(suggestion_.receive({.request_id = failed_request, .status = SuggestionStatus::failed}));

      return false;
    }

    const SuggestCommand request{.request_id = nextRequest(), .pane_id = pane->id, .text = text};
    transport_.send(request);
    suggestion_.expect(request.request_id);

    return false;
  }

  inline bool beginPathPicker() {
    const auto *pane = focusedPane();
    if (!ready_ || copy_mode_.active() || pane == nullptr || !pane->attached || pane->exited || !std::string_view{pane->cwd}.starts_with('/')) {
      return false;
    }

    path_picker_.begin(pane->id, pane->cwd);
    seedPathPicker(pane->id);
    requestPaths(path_seed_.text.view());

    return true;
  }

  // The word the island's search for a path started from, which the path chosen replaces.
  [[nodiscard]] inline std::string_view pathSeed() const noexcept {
    return path_seed_.text.view();
  }

  inline bool requestPaths(std::string_view query) {
    if (!ready_ || path_picker_.paneId() == 0) {
      return false;
    }

    const FindPaths request{
        .request_id = nextRequest(),
        .root = path_picker_.root(),
        .query = runtime::utf8Prefix(query, PathPickerLimits::query_bytes),
        .kind = PathKindFilter::any,
        .limit = static_cast<std::uint16_t>(PathPickerLimits::results),
        .refresh = path_picker_.refreshRequested(),
    };
    try {
      transport_.send(request);
    } catch (const std::length_error &) {
      path_picker_.setError("Path request queue is full; retry");

      return false;
    }

    path_picker_.expect(request.request_id);

    return true;
  }

  inline bool descendPath(std::size_t selection) {
    const auto matches = path_picker_.matches();
    if (matches.empty()) {
      return false;
    }

    const auto &match = matches[std::min(selection, matches.size() - 1)];
    if (match.kind != PathKind::directory) {
      return false;
    }

    auto relative = path_picker_.path(match);
    const auto last = relative.find_last_not_of('/');
    relative.remove_suffix(last == std::string_view::npos ? relative.size() : relative.size() - last - 1);
    const auto directory = PathInsertion::join({.root = path_picker_.root(), .relative = relative});
    if (directory.view().size() > PathPickerLimits::root_bytes) {
      return false;
    }

    path_picker_.setRoot(directory.view());
    requestPaths({});

    return true;
  }

  inline bool ascendPath() {
    const auto root = path_picker_.root();
    if (root.size() <= 1) {
      return false;
    }

    const auto separator = root.rfind('/');
    if (separator == std::string_view::npos) {
      return false;
    }

    path_picker_.setRoot(separator == 0 ? root.substr(0, 1) : root.substr(0, separator));
    requestPaths({});

    return true;
  }

  inline void closePathPicker() noexcept {
    path_picker_.close();
    path_seed_ = {};
  }

  inline bool insertPath(std::size_t selection, bool absolute) {
    if (path_picker_.matches().empty()) {
      path_picker_.setError(path_picker_.phase() == PathPickerPhase::loading ? "Searching..." : "No path to insert");

      return false;
    }

    const auto *pane = focusedPane();
    if (!ready_ || pane == nullptr || !pane->attached || pane->exited || copy_mode_.active()) {
      path_picker_.setError("Input is busy; retry");

      return false;
    }

    const bool editor = editsPrompt(pane->id);
    const auto paste = PathInsertion::prepare(path_picker_, {.selection = selection, .absolute = absolute, .bracketed = !editor && pane->screen.modes().bracketed_paste});
    if (!paste) {
      return false;
    }

    try {
      if (editor && replacePathSeed(pane->id, paste->view())) {
        prompt_written_ = pane->id;
      } else if (editor) {
        promptText(pane->id, paste->view());
      } else {
        input(pane->id, paste->view());
      }
    } catch (const std::length_error &) {
      path_picker_.setError("Input is busy; retry");

      return false;
    }

    closePathPicker();

    return true;
  }

  [[nodiscard]] inline const PathPickerPage &pathPicker() const noexcept {
    return path_picker_;
  }

  inline void reportHistoryError(std::string_view message) {
    history_.setError(message);
  }

  inline void visitHistory(std::uint64_t entry_id) {
    visitPane(history_.entry(entry_id).pane_id);
  }

  inline void visitPane(std::uint64_t pane_id, std::optional<std::uint64_t> generation = {}) {
    if (!ready_ || !presented_) {
      return;
    }

    const auto *pane = findPane(pane_id);
    if (pane != nullptr && (!generation || pane->generation == *generation) && active_tab_ && sameWorkspace(pane->location.workspace, active_tab_->workspace)) {
      focusPane(pane_id);
    } else if (!requestsPending()) {
      const auto agent = std::ranges::find_if(agents_, [&](const auto &entry) {
        return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
      });
      const auto listed = std::ranges::find_if(pane_list_.entries(), [&](const auto &entry) {
        return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
      });
      const auto location = agent != agents_.end() ? std::optional{agent->location} : listed != pane_list_.entries().end() ? std::optional{listed->location} : std::nullopt;
      const auto fallback = location && location->workspace.kind == WorkspaceLocation::Kind::workspace ? std::optional{location->workspace.id} : std::nullopt;
      handoffPane(pane_id, fallback);
    }
  }

  inline bool focusAgent(std::uint64_t pane_id, std::uint64_t generation) {
    const auto agent = std::ranges::find_if(agents_.entries(), [&](const auto &entry) {
      return entry.pane_id == pane_id && entry.pane_generation == generation;
    });
    if (agent == agents_.entries().end()) {
      return false;
    }

    visitPane(pane_id, generation);

    return true;
  }

  inline bool focusListedPane(std::uint64_t pane_id, std::uint64_t generation) {
    if (pane_list_.find(pane_id, generation) == nullptr) {
      return false;
    }

    visitPane(pane_id, generation);

    return true;
  }

  [[nodiscard]] inline const auto &peek() const noexcept {
    return peek_;
  }

  [[nodiscard]] inline const Agent<Memory> *peekAgent() const noexcept {
    if (!peek_.target()) {
      return nullptr;
    }

    return findPeekAgent(*peek_.target());
  }

  inline bool openPeek(PeekTarget target) {
    if (!ready_ || !presented_ || findPeekAgent(target) == nullptr) {
      return false;
    }

    peek_.show(target);
    try {
      requestPeekScreen();
    } catch (...) {
      peek_.close();
      throw;
    }

    return true;
  }

  inline void closePeek() noexcept {
    if (peek_.target()) {
      peek_.close();
    }
  }

  inline bool submitPeek(std::string_view text) {
    const auto *agent = ready_ && presented_ ? peekAgent() : nullptr;
    if (agent == nullptr) {
      closePeek();

      return false;
    }

    if (text.size() > PeekLimits::message_bytes) {
      throw std::length_error{"PeekMessageTooLong"};
    }

    switch (PeekInput::command(text)) {
    case PeekCommand::open:
      static_cast<void>(focusAgent(agent->pane_id, agent->pane_generation));
      break;
    case PeekCommand::stop:
      sendPeekAction(InterruptAgent{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation}, agent->pane_id);
      break;
    case PeekCommand::diff:
      openPeekDiff(*agent);
      break;
    case PeekCommand::message:
      sendPeekAction(SendPaneText{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation, .mode = PaneTextMode::prompt, .text = PeekInput::trim(text), .sender = {}}, agent->pane_id);
      break;
    }

    closePeek();

    return true;
  }

  inline void deleteHistory(std::uint64_t entry_id) {
    sendHistory(history_.erase(entry_id, nextRequest()));
  }

  inline void selectHistoryRow(std::size_t row) {
    if (history_.select(row)) {
      refreshHistoryDetails();
    }
  }

  inline void inspectHistory(bool enabled) {
    history_.setInspecting(enabled);
    refreshHistoryDetails();
  }

  inline void resize(std::uint64_t pane_id, TerminalSize size) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || equalSize(pane->size, size)) {
      return;
    }

    if (pane->attached) {
      transport_.send(PaneResize{.pane_id = pane_id, .size = size});
    }

    pane->size = size;
    ++view_version_.viewport;
  }

  inline void presented(std::uint64_t pane_id, std::uint64_t frame_id) {
    auto *pane = findPane(pane_id);
    if (ready_ && pane != nullptr && pane->attached && frame_id > pane->acknowledged_frame && frame_id <= pane->screen.frameId()) {
      transport_.send(FrameAck{.pane_id = pane_id, .frame_id = frame_id});
      pane->acknowledged_frame = frame_id;
    }
  }

  inline void scroll(PaneScrollDelta delta) {
    auto *pane = findPane(delta.pane_id);
    if (pane == nullptr || !pane->attached || copy_mode_.active()) {
      return;
    }

    const auto &viewport = pane->screen.scroll();
    const auto maximum = std::max<std::int64_t>(0, static_cast<std::int64_t>(viewport.total_rows) - pane->screen.rows());
    const auto offset = static_cast<std::int64_t>(viewport.offset);
    const auto bounded_delta = std::clamp(delta.rows, offset - maximum, offset);
    const auto requested = static_cast<std::uint32_t>(offset - bounded_delta);
    if (requested == viewport.offset) {
      return;
    }

    // The bottom as this replica knows it may be behind the runtime's: ask to follow instead.
    ++pane->viewport_requests;
    transport_.send(SetPaneViewport{.pane_id = delta.pane_id, .offset = requested == maximum ? follow_output : requested});
    pane->screen.setViewport(requested);
    ++view_version_.viewport;
  }

  inline void scrollFocused(ScrollDirection direction) {
    const auto *pane = focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      return;
    }

    const auto &mouse = pane->screen.mouse();
    if (mouse.sgr && mouse.tracking != MouseTracking::none && mouse.tracking != MouseTracking::x10) {
      MouseEncoder encoder;
      input(pane->id, encoder.encode(direction == ScrollDirection::up ? MouseEncoder::wheel_up : MouseEncoder::wheel_down, 1, 1, false, true), PaneInputSource::mouse);

      return;
    }

    const auto delta = direction == ScrollDirection::up ? WheelAccumulator::rows_per_line : -WheelAccumulator::rows_per_line;
    const auto &modes = pane->screen.modes();
    if (modes.alternate_scroll && modes.alternate_screen && pane->screen.scroll().offset == copyGrid(pane->screen).maximumOffset()) {
      const std::string_view bytes = direction == ScrollDirection::up ? "\x1b[A" : "\x1b[B";
      for (std::int32_t step = 0; step < WheelAccumulator::rows_per_line; ++step) {
        input(pane->id, bytes, PaneInputSource::mouse);
      }
    } else {
      scroll({.pane_id = pane->id, .rows = delta});
    }
  }

  [[nodiscard]] inline const CopyMode &copyMode() const noexcept {
    return copy_mode_;
  }

  inline bool beginSelection(CopyPress press) noexcept {
    const auto *pane = focusedPane();
    if (pane == nullptr || pane->id != press.pane_id || !pane->attached) {
      return false;
    }

    return copy_mode_.beginPointer(press, copyGrid(pane->screen));
  }

  inline bool copySelection(std::uint64_t pane_id) {
    const auto &state = copy_mode_.state();
    if (!state || state->pane_id != pane_id || !state->pointer) {
      return false;
    }

    const auto selection = state->selectionRequest();
    if (!selection) {
      return false;
    }

    transport_.send(*selection);

    return true;
  }

  inline CopyPointerDecision::Outcome pointer(const CopyPointerInput &input) {
    const auto decision = routeCopyPointer(input, pointerAuthority(input));
    const auto finish = decision.cancel || (decision.motion && input.kind == CopyPointerKind::release);
    try {
      if (decision.leave) {
        leaveCopyMode();
      } else if (decision.cancel) {
        static_cast<void>(copy_mode_.clearPointer());
      } else if (auto *pane = copyPane(); pane != nullptr) {
        applyPointerMotion(decision, input.kind == CopyPointerKind::release, *pane);
      }
    } catch (...) {
      if (finish) {
        copy_mode_.finishPointer();
      }

      throw;
    }

    if (finish) {
      copy_mode_.finishPointer();
    }

    return decision.outcome;
  }

  inline bool enterCopyMode() noexcept {
    const auto *pane = focusedPane();
    if (pane == nullptr || !pane->attached) {
      return false;
    }

    const auto entered = copy_mode_.enter(pane->id, copyGrid(pane->screen), pane->screen.cursor());
    if (entered) {
      copy_search_request_ = 0;
    }

    return entered;
  }

  inline CopyEffect copyKey(const TerminalKey &key) {
    auto *pane = copyPane();
    if (pane == nullptr) {
      return {.handled = false};
    }

    const auto plan = copy_mode_.key(key, copyGrid(pane->screen));
    if (!plan) {
      return {};
    }

    applyCopyPlan(*plan, *pane);
    // A search begins from where the cursor is now.
    if (plan->effect.search) {
      copy_search_origin_.reset();
      copy_search_query_.clear();
    }

    return plan->effect;
  }

  inline void leaveCopyMode() {
    if (auto *pane = copyPane()) {
      applyCopyPlan(copy_mode_.leave(copyGrid(pane->screen)), *pane);
    } else {
      copy_mode_.reset();
    }

    copy_search_request_ = 0;
    copy_search_rows_.reset();
    copy_search_origin_.reset();
    copy_search_query_.clear();
  }

  inline void searchCopy(std::string_view needle) {
    auto *pane = copyPane();
    if (pane == nullptr || !copy_mode_.active()) {
      throw EncodingError{"No copy mode owns this search"};
    }

    // A search typed a letter at a time starts where the first letter found the cursor.
    if (!copy_search_origin_) {
      copy_search_origin_ = copy_mode_.state()->cursor;
    }
    copy_search_query_.assign(needle);
    if (needle.empty()) {
      // Nothing to look for: no matches, and the cursor back where the search began.
      copy_search_request_ = 0;
      copy_search_truncated_ = false;
      if (const auto plan = copy_mode_.search({}, copyGrid(pane->screen), copy_search_origin_)) {
        applyCopyPlan(*plan, *pane);
      }
      changed_pane_ = pane->id;
      return;
    }
    const auto request_id = nextRequest();
    if (copy_search_rows_ && copy_search_scoped_ && readsRows()) {
      transport_.send(SearchPaneRows{.request_id = request_id, .pane_id = pane->id, .needle = needle, .first_row = copy_search_rows_->first, .last_row = copy_search_rows_->last});
    } else {
      transport_.send(SearchPane{.request_id = request_id, .pane_id = pane->id, .needle = needle});
    }
    copy_search_request_ = request_id;
  }

  // The search typed so far ends: its matches stay for n and N, from wherever they took the
  // cursor.
  inline void finishCopySearch() noexcept {
    copy_search_origin_.reset();
  }

  // What the copy-mode search looks for, whether an answer is awaited, and how its matches
  // stand: how many, which the cursor is on, and whether there were more than it kept.
  struct CopySearchState {
    std::string_view query;
    bool searching = false;
    std::size_t count = 0;
    std::size_t index = 0;
    bool truncated = false;
  };

  [[nodiscard]] inline CopySearchState copySearch() const noexcept {
    const auto &state = copy_mode_.state();
    return {.query = copy_search_query_, .searching = copy_search_request_ != 0, .count = copy_mode_.matches().size(), .index = state ? std::size_t{state->match_index} : std::size_t{0}, .truncated = copy_search_truncated_};
  }

  // The next match or the one before, as n and N go.
  inline void stepCopyMatch(bool forward) {
    TerminalKey key{.code = KeyChord::Key::character, .codepoint = static_cast<std::uint32_t>(forward ? 'n' : 'N')};
    static_cast<void>(copyKey(key));
  }

  // The command whose output the copy-mode search reads, while it reads only that output.
  [[nodiscard]] inline std::optional<std::size_t> copySearchBlock() const noexcept {
    return copy_search_rows_ && copy_search_scoped_ ? std::optional{copy_search_rows_->block} : std::nullopt;
  }

  // Whether a search can be confined to a command's output, as one began from a command can.
  [[nodiscard]] inline bool copySearchScopes() const noexcept {
    return copy_search_rows_.has_value() && readsRows();
  }

  // Between that command's output and the whole scrollback.
  inline void toggleCopySearchScope() noexcept {
    if (copySearchScopes()) {
      copy_search_scoped_ = !copy_search_scoped_;
    }
  }

  // Whether a key asked for the scrollback search since the last call.
  [[nodiscard]] inline bool takeSearchRequest() noexcept {
    return std::exchange(search_requested_, false);
  }

  inline void queryHistory(std::string_view query) {
    queryHistory(query, {.author = configuration_.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  inline void queryHistory(std::string_view query, HistoryFilters filters) {
    const auto parsed = HistorySearch::parse(query, filters.failed_only);
    // Each command once, at its newest run that passes the filters.
    QueryHistory request{.request_id = nextRequest(), .query = parsed.query, .failed_only = parsed.failed_only, .author = filters.author, .match = configuration_.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy, .distinct = true};
    resolveHistoryScope(request, filters.scope);
    sendHistory(history_.begin(request));
  }

  inline bool pageHistory(HistoryPage direction) {
    if (const auto request = history_.page(direction, nextRequest())) {
      sendHistory(*request);

      return true;
    }

    return false;
  }

  [[nodiscard]] inline bool historyLoading() const noexcept {
    return history_.state().phase == HistoryPhase::loading;
  }

  [[nodiscard]] inline const HistoryBrowser<Memory> &historyBrowser() const noexcept {
    return history_;
  }

  inline void toggleFullscreen() {
    if (auto *tab = activeTab()) {
      ++view_version_.panes;
      tab->fullscreen = !tab->fullscreen;
      synchronizeAttachments();
      retainLayout();
    }
  }

  inline void retainLayout() {
    if (!ready_ || !active_tab_) {
      return;
    }

    std::array<ClientTabLayout, maximum_tabs> layouts;
    std::size_t count = 0;
    std::size_t retained_nodes = 0;
    const auto append = [&](const Tab<Memory> &tab) {
      if (!tab.loaded || tab.layout.nodes().empty() || tab.focused_pane == 0 || retained_nodes + tab.layout.nodes().size() > maximum_retained_layout_nodes) {
        return;
      }

      layouts[count++] = {tab.location, tab.focused_pane, tab.fullscreen, tab.workspace_active, tab.layout.nodes()};
      retained_nodes += tab.layout.nodes().size();
    };

    if (const auto *active = activeTab()) {
      append(*active);
    }

    for (const auto &tab : tabs_) {
      if (!sameTab(tab->location, *active_tab_)) {
        append(*tab);
      }
    }

    const auto active_found = std::any_of(layouts.begin(), layouts.begin() + count, [&](const auto &layout) {
      return sameTab(layout.location, *active_tab_);
    });
    if (active_found) {
      transport_.send(UpdateClientLayout{.sidebar_visible = configuration_.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .active_tab = *active_tab_, .tabs = {layouts.data(), count}});
    }
  }

  inline void setDisplayRefreshRate(std::uint16_t fps) noexcept {
    display_fps_ = std::clamp(fps, Configuration::minimum_fps, Configuration::maximum_fps);
  }

  inline void configureCadence() {
    const auto maximum_fps = configuration_.max_fps == 0 ? std::nullopt : std::optional{configuration_.max_fps};
    const auto interval_ns = FramePacer::resolveInterval(FramePacer::nanoseconds_per_second / display_fps_, maximum_fps);
    transport_.send(ConfigureFrameInterval{static_cast<std::uint32_t>(interval_ns)});
  }

  [[nodiscard]] inline Pane<Memory> *findPane(std::uint64_t pane_id) const noexcept {
    const auto found = std::find_if(panes_.begin(), panes_.end(), [&](const auto &pane) {
      return pane->id == pane_id;
    });

    return found == panes_.end() ? nullptr : found->get();
  }

  [[nodiscard]] inline Tab<Memory> *activeTab() const noexcept {
    return active_tab_ ? findTab(*active_tab_) : nullptr;
  }

  [[nodiscard]] inline Pane<Memory> *focusedPane() const noexcept {
    const auto *tab = activeTab();

    return tab == nullptr ? nullptr : findPane(tab->focused_pane);
  }

  [[nodiscard]] inline const auto &tabs() const noexcept {
    return tabs_;
  }

  [[nodiscard]] inline const auto &panes() const noexcept {
    return panes_;
  }

  [[nodiscard]] inline const auto &workspaces() const noexcept {
    return workspaces_.entries();
  }

  [[nodiscard]] inline const auto &workspaceList() const noexcept {
    return workspaces_;
  }

  [[nodiscard]] inline const auto &agents() const noexcept {
    return agents_.entries();
  }

  [[nodiscard]] inline std::uint64_t agentRevision() const noexcept {
    return agents_.revision();
  }

  [[nodiscard]] inline std::span<const ListedPane> paneList() const noexcept {
    return pane_list_.entries();
  }

  [[nodiscard]] inline std::uint64_t paneListRevision() const noexcept {
    return pane_list_.revision();
  }

  [[nodiscard]] inline const auto &history() const noexcept {
    return history_.rows();
  }

  [[nodiscard]] inline std::string_view clipboard() const noexcept {
    return clipboard_;
  }

  [[nodiscard]] inline std::string_view notice() const noexcept {
    return notice_;
  }

  [[nodiscard]] inline const NotificationCenter &notifications() const noexcept {
    return notifications_;
  }

  [[nodiscard]] inline std::uint64_t notificationRevision() const noexcept {
    return notification_revision_;
  }

  [[nodiscard]] inline bool graphicsPaused(std::uint64_t pane_id) const noexcept {
    return graphics_pauses_.contains(pane_id);
  }

  [[nodiscard]] inline std::uint64_t graphicsRecoveryRevision() const noexcept {
    return graphics_pauses_.revision();
  }

  [[nodiscard]] inline std::optional<std::uint64_t> graphicsResumeDeadline() const noexcept {
    return graphics_pauses_.nextDeadline();
  }

  inline void resumeGraphics() {
    if (ready_) {
      graphics_pauses_.resumeDue(Clock::nowNanoseconds(), [this](std::uint64_t pane_id) {
        requestGraphicsSnapshot(pane_id);
      });
    }
  }

  inline void publishNotification(NotificationInput input) {
    publishNotificationAt(input, Clock::nowNanoseconds());
  }

  inline void reportLimit(LimitReach reach) {
    const auto recorded = countLimitReach(reach);
    if (recorded.show) {
      const auto &row = limit_reports_.row(recorded.slot);
      const auto message = LimitReports::describe(row.reach(), row.hits);
      publishNotification({.level = NotificationLevel::warning, .title = "Limit reached", .message = message.view(), .link = {}, .duration_ns = limit_notice_duration_ns});
    }
  }

  inline void completeAgentSound() {
    if (const auto next = sound_playback_.complete()) {
      startAgentSound(*next);
    }
  }

  inline bool advanceNotifications(std::uint64_t now_ns) noexcept {
    if (!notifications_.advance(now_ns)) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  inline bool dismissNotification(NotificationId id) noexcept {
    if (!notifications_.dismiss(id, Clock::nowNanoseconds())) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  inline bool activateNotification(NotificationId id) {
    const auto target = notifications_.activate(id, Clock::nowNanoseconds());
    if (!target) {
      return false;
    }

    ++notification_revision_;
    switch (target->kind) {
    case NotificationTarget::Kind::pane:
      focusPane(target->id);
      break;
    case NotificationTarget::Kind::tab: {
      const auto tab = std::ranges::find_if(tabs_, [&](const auto &candidate) {
        return candidate->location.tab_id == target->id;
      });
      if (tab != tabs_.end()) {
        selectTab((*tab)->location);
      }
    } break;
    case NotificationTarget::Kind::workspace:
      selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = target->id});
      break;
    case NotificationTarget::Kind::none:
      break;
    }

    return true;
  }

  [[nodiscard]] inline bool notificationTargetVisible(NotificationTarget target) const noexcept {
    const auto *tab = activeTab();

    return target.kind == NotificationTarget::Kind::pane && tab != nullptr && tab->layout.contains(target.id);
  }

  [[nodiscard]] inline WindowTitle windowTitle(std::string_view hostname) const {
    const auto *tab = activeTab();
    const auto *pane = focusedPane();
    WindowTitle::Tokens tokens{.workspace = {}, .tab = {}, .pane_title = pane != nullptr ? std::string_view{pane->title} : std::string_view{}, .hostname = hostname};
    if (tab != nullptr) {
      if (!tab->label.empty()) {
        tokens.tab = tab->label;
      } else {
        tokens.tab = tabApplicationName(*tab, pane);
      }
      const auto workspace = std::ranges::find_if(workspaces_, [&](const auto &entry) {
        return sameWorkspace(entry.location, tab->location.workspace);
      });
      if (workspace != workspaces_.end()) {
        tokens.workspace = workspace->name;
      }
    }

    const auto pattern = configuration_.window_title.view();
    return WindowTitle::render(pattern.empty() ? WindowTitle::default_title : pattern, tokens);
  }

  [[nodiscard]] inline std::string_view error() const noexcept {
    return error_;
  }

  inline void dismissDiagnostic() noexcept {
    error_.clear();
  }

  [[nodiscard]] inline bool ready() const noexcept {
    return ready_;
  }

  [[nodiscard]] inline std::uint64_t changedPane() const noexcept {
    return changed_pane_;
  }

  [[nodiscard]] inline const Configuration &configuration() const noexcept {
    return configuration_;
  }

  [[nodiscard]] inline ClientViewState clientViewState() const noexcept {
    return {.sidebar_visible = configuration_.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .pane_gaps = configuration_.pane_gaps, .window_title = configuration_.window_title.view()};
  }

  inline void configure(const Configuration &configuration) {
    const bool prompt_changed = configuration_.prompt.mode != configuration.prompt.mode;
    configuration_ = configuration;
    sound_playback_.configure(configuration.sound);
    ++view_version_.configuration;
    if (prompt_changed) {
      configureShellPrompt();
    }
  }

  // Tells the runtime whether telar's editor stands in for the shell's prompt: the shells of the
  // panes it opens from now on print no prompt of their own. A cqp00002 runtime cannot hear it.
  inline void configureShellPrompt() {
    if (ready_ && reads_rows_) {
      transport_.send(ConfigureShellPrompt{.bare = configuration_.prompt.mode == PromptMode::telar});
    }
  }

  inline void setTheme(const Theme &theme) {
    if (configuration_.theme == theme) {
      return;
    }

    configuration_.theme = theme;
    ++view_version_.configuration;
  }

  [[nodiscard]] inline ViewVersion viewVersion() const noexcept {
    return view_version_;
  }

  inline void invalidateView() noexcept {
    ++view_version_.host;
  }

  inline void setSidebarVisible(bool visible) {
    if (configuration_.sidebar_visible != visible) {
      ++view_version_.host;
    }

    configuration_.sidebar_visible = visible;
    retainLayout();
  }

  inline void setSidebarWidth(float width) {
    if (configuration_.sidebar_width != width) {
      ++view_version_.host;
    }

    configuration_.sidebar_width = width;
  }

  inline void setHostColumns(std::uint16_t columns) noexcept {
    host_columns_ = columns;
  }

  [[nodiscard]] inline bool workspaceListCollapsed() const noexcept {
    return workspace_list_collapsed_;
  }

  inline void setWorkspaceListCollapsed(bool collapsed) {
    if (workspace_list_collapsed_ == collapsed) {
      return;
    }

    workspace_list_collapsed_ = collapsed;
    retainLayout();
  }

  [[nodiscard]] inline const SystemMetrics &metrics() const noexcept {
    return metrics_.sample();
  }

  [[nodiscard]] inline const HostMetrics &hostMetrics() const noexcept {
    return metrics_;
  }

  [[nodiscard]] inline const ProxyStatus &proxyStatus() const noexcept {
    return proxy_;
  }

private:
  // At the island's prompt, the search starts from the word before the caret when it is a
  // plain relative path, as `src/ma` is; anything else starts empty and inserts at the caret.
  inline void seedPathPicker(std::uint64_t pane_id) {
    path_seed_ = {};
    const auto found = islands_.find(pane_id);
    if (promptSurface(pane_id) != prompt::Surface::editor || found == islands_.end()) {
      return;
    }

    const auto &text = found->second.island.editor().text();
    const auto before = text.view().substr(0, text.cursor());
    const auto space = before.find_last_of(" \t\n");
    const auto begin = space == std::string_view::npos ? 0 : space + 1;
    const auto word = before.substr(begin);
    if (word.empty() || word.size() > PathPickerLimits::query_bytes || word.front() == '/' || word.front() == '~' || !PathInsertion::plain(word)) {
      return;
    }

    path_seed_.pane_id = pane_id;
    path_seed_.begin = begin;
    path_seed_.text.assign(word);
  }

  // Writes `path` over the word the search started from, while the editor still holds it.
  inline bool replacePathSeed(std::uint64_t pane_id, std::string_view path) {
    const auto word = path_seed_.text.view();
    const auto found = islands_.find(pane_id);
    if (path_seed_.pane_id != pane_id || word.empty() || found == islands_.end()) {
      return false;
    }

    auto &island = found->second.island;
    const auto &text = island.editor().text();
    const auto end = path_seed_.begin + word.size();
    if (text.cursor() != end || text.view().substr(path_seed_.begin, word.size()) != word) {
      return false;
    }

    island.replaceText(path_seed_.begin, end, path);
    return true;
  }

  enum class RequestKind : std::uint8_t {
    open_default,
    attach,
    split,
    create_tab,
    rename_tab,
    move_tab,
    create_workspace,
    close_pane,
    close_tab,
    visit_pane,
    forget_worktree,
    tab_snapshot,
    workspace_snapshot,
    restore_machine,
    peek_screen,
    peek_action,
    peek_diff,
  };

  struct Pending {
    std::uint64_t id = 0;
    RequestKind kind = RequestKind::open_default;
    std::uint64_t pane_id = 0;
    ClientLayoutAxis axis = ClientLayoutAxis::horizontal;
    TabLocation location{};
    TerminalSize size = default_terminal_size;
    std::optional<std::uint64_t> fallback_workspace = std::nullopt;
  };

  struct MachineBookmark {
    TabLocation location;
    std::uint64_t pane_id = 0;
    std::optional<std::uint64_t> fallback_workspace;
  };

  struct SplitSizes {
    TerminalSize existing;
    TerminalSize added;
  };

  [[nodiscard]] inline const Agent<Memory> *findPeekAgent(const PeekTarget &target) const noexcept {
    const auto found = std::ranges::find_if(agents_, [&](const auto &agent) {
      return agent.pane_id == target.agent.pane_id && agent.pane_generation == target.agent.pane_generation && agent.session_id == target.session;
    });

    return found == agents_.end() ? nullptr : std::addressof(*found);
  }

  inline void requestPeekScreen() {
    if (!peek_.target() || peek_.reading()) {
      return;
    }

    const auto request_id = pending(RequestKind::peek_screen);
    try {
      if (const auto request = peek_.request(request_id)) {
        transport_.send(*request);
      } else {
        complete(request_id);
      }
    } catch (...) {
      peek_.fail(request_id);
      complete(request_id);
      throw;
    }
  }

  template <typename Request>
    requires(std::same_as<Request, InterruptAgent> || std::same_as<Request, SendPaneText> || std::same_as<Request, LaunchWorktree>)
  void sendPeekAction(Request request, std::uint64_t pane_id) {
    constexpr auto kind = std::same_as<Request, LaunchWorktree> ? RequestKind::peek_diff : RequestKind::peek_action;
    request.request_id = pending(kind, pane_id);
    try {
      transport_.send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  inline void openPeekDiff(const Agent<Memory> &agent) {
    const auto *row = AgentOrder::taskRow(workspaces_, agent);
    if (row == nullptr) {
      return;
    }

    constexpr std::string_view script = R"("$TELAR_BIN_PATH" worktree diff "$1" --stat; echo; "$TELAR_BIN_PATH" worktree diff "$1"; exec "${SHELL:-/bin/sh}")";
    constexpr TerminalSize size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};
    const std::array<std::string_view, 5> arguments{"sh", "-c", script, "sh", row->branch};
    sendPeekAction(LaunchWorktree{.worktree = row->id, .label = "diff", .size = size, .launch = {.cwd = row->path.empty() ? std::string_view{"/"} : std::string_view{row->path}, .arguments = arguments}}, agent.pane_id);
  }

  inline std::optional<Change> failPeekRequest(const Pending &request, const RequestFailed &failure) {
    if (request.kind == RequestKind::peek_screen) {
      peek_.fail(failure.request_id);

      return Change::none;
    }

    if (request.kind != RequestKind::peek_action && request.kind != RequestKind::peek_diff) {
      return std::nullopt;
    }

    constexpr std::uint64_t duration_ns = 7'000'000'000;
    publishNotification({.level = NotificationLevel::failure, .target = {.kind = NotificationTarget::Kind::pane, .id = request.pane_id}, .title = "The agent did not take it", .message = failure.message, .link = {}, .duration_ns = duration_ns});

    return Change::notification;
  }

  [[nodiscard]] TerminalSize launchSize() const {
    const auto size = workbench_geometry_.launchSize();
    if (!size) {
      throw std::runtime_error{"TerminalTooSmall"};
    }

    return *size;
  }

  template <typename Request>
    requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
  void sendOpeningRequest(RequestKind kind, Request request, TabLocation location = TabLocation(), std::optional<std::uint64_t> fallback_workspace = std::nullopt) {
    request.request_id = pending(kind);
    auto &registered = pending_[pending_count_ - 1];
    registered.size = request.size;
    registered.location = location;
    registered.fallback_workspace = fallback_workspace;
    if constexpr (std::same_as<Request, OpenPane>) {
      registered.pane_id = request.target.kind == PaneTarget::Kind::pane ? request.target.id : 0;
    }

    try {
      transport_.send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  template <typename Request>
    requires(std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot>)
  void sendSnapshotRequest(Request request) {
    constexpr auto kind = std::same_as<Request, RequestTabSnapshot> ? RequestKind::tab_snapshot : RequestKind::workspace_snapshot;
    request.request_id = pending(kind);
    auto &registered = pending_[pending_count_ - 1];
    if constexpr (std::same_as<Request, RequestTabSnapshot>) {
      registered.location = request.location;
    } else {
      registered.location.workspace = request.workspace;
    }

    try {
      transport_.send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  bool completeRequest(RequestKind kind, std::uint64_t request_id) noexcept {
    const auto requests = std::span{pending_}.first(pending_count_);
    const auto found = std::ranges::find_if(requests, [&](const Pending &request) {
      return request.id == request_id && request.kind == kind;
    });
    if (found == requests.end()) {
      return false;
    }

    complete(request_id);

    return true;
  }

  [[nodiscard]] bool hasPaneOperation() const noexcept {
    return std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const auto &request) {
      return request.kind == RequestKind::split || request.kind == RequestKind::close_pane;
    });
  }

  [[nodiscard]] std::optional<SplitSizes> splitSizes(Tab<Memory> &tab, std::uint64_t pane_id, ClientLayoutAxis axis) noexcept {
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

  bool requestPaneSplit(std::uint64_t pane_id, ClientLayoutAxis axis, Launch launch) {
    auto *tab = activeTab();
    const auto *pane = findPane(pane_id);
    if (hasPaneOperation() || tab == nullptr || pane == nullptr || !pane->attached || pane->exited || !sameTab(pane->location, tab->location)) {
      return false;
    }

    const auto sizes = splitSizes(*tab, pane_id, axis);
    if (!sizes) {
      return false;
    }

    const auto request_id = pending(RequestKind::split, pane_id, axis);
    auto &registration = pending_[pending_count_ - 1];
    registration.location = tab->location;
    registration.size = sizes->added;
    const auto registered = registration;
    launch.cwd_source = pane_id;
    try {
      transport_.send(PaneResize{.pane_id = pane_id, .size = sizes->existing});
      transport_.send(CreatePane{.request_id = request_id, .location = tab->location, .size = sizes->added, .launch = launch});
    } catch (...) {
      complete(request_id);
      recoverSplit(registered);
      throw;
    }

    return true;
  }

  void recoverSplit(const Pending &request) {
    auto *tab = activeTab();
    const auto *pane = findPane(request.pane_id);
    if (tab == nullptr || pane == nullptr || !pane->attached || !sameTab(tab->location, request.location) || !sameTab(pane->location, request.location)) {
      return;
    }

    const auto fullscreen = tab->fullscreen ? std::optional{tab->focused_pane} : std::nullopt;
    const auto placements = tab->layout.arrange(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, fullscreen);
    const auto target = std::ranges::find(placements, request.pane_id, &PaneLayout::Placement::pane_id);
    if (target != placements.end()) {
      if (const auto size = workbench_geometry_.contentSize(target->content)) {
        transport_.send(PaneResize{.pane_id = request.pane_id, .size = *size});
      }
    }
  }

  void resizeVisiblePanes(Tab<Memory> &tab) {
    const auto fullscreen = tab.fullscreen ? std::optional{tab.focused_pane} : std::nullopt;
    const auto placements = tab.layout.arrange(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, fullscreen);
    for (const auto &placement : placements) {
      if (const auto size = workbench_geometry_.contentSize(placement.content)) {
        resize(placement.pane_id, *size);
      }
    }
  }

  Pane<Memory> &allocateSplitPane(const Pending &request, const PaneOpened &message) {
    try {
      return ensurePane(message.pane_id, message.location);
    } catch (...) {
      recoverSplit(request);
      transport_.send(DetachPane{message.pane_id});
      throw;
    }
  }

  Change adoptSplit(const Pending &request, const PaneOpened &message) {
    if (!message.created || message.pane_id == 0 || message.pane_id == request.pane_id || !sameTab(message.location, request.location)) {
      throw EncodingError{"UnexpectedPaneSplit"};
    }

    auto *tab = findTab(request.location);
    if (tab == nullptr) {
      if (findPane(message.pane_id) == nullptr) {
        transport_.send(DetachPane{message.pane_id});
      }

      return Change::none;
    }

    if (!tab->layout.contains(message.pane_id) && tab->layout.nodes().size() + 2 > PaneLayout::maximum_nodes) {
      throw EncodingError{"Pane layout exceeds capacity"};
    }

    const auto *known = findPane(message.pane_id);
    if (known != nullptr && !sameTab(known->location, request.location)) {
      throw EncodingError{"Pane already belongs to another tab"};
    }

    auto &pane = allocateSplitPane(request, message);
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
      transport_.send(DetachPane{pane.id});
    }

    ++view_version_.panes;
    synchronizeAttachments();
    retainLayout();

    if (message.pane_generation == 0) {
      sendSnapshotRequest(RequestTabSnapshot{.location = message.location});
    }

    return Change::model;
  }

  [[nodiscard]] bool hasTabOperation() const noexcept {
    return std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const auto &request) {
      return request.kind == RequestKind::create_tab || request.kind == RequestKind::rename_tab || request.kind == RequestKind::move_tab || request.kind == RequestKind::close_tab;
    });
  }

  template <typename Request>
  void sendTabOperation(RequestKind kind, Request request) {
    request.request_id = pending(kind);
    auto &registered = pending_[pending_count_ - 1];
    if constexpr (std::same_as<Request, CreateTab>) {
      registered.location.workspace = request.workspace;
      registered.size = request.size;
    } else {
      registered.location = request.location;
    }

    try {
      transport_.send(request);
    } catch (...) {
      complete(request.request_id);
      throw;
    }
  }

  template <typename Value>
  static void reserveAppend(Vector<Value, Memory> &values, std::size_t maximum) {
    if (values.size() < values.capacity()) {
      return;
    }

    constexpr std::size_t growth_factor = 2;
    const auto grown = values.capacity() > maximum / growth_factor ? maximum : values.capacity() * growth_factor;
    values.reserve(std::max(values.size() + 1, grown));
  }

  TabCreationOutcome requestTabCreation(std::string_view label, std::span<const std::string_view> arguments) {
    if (hasTabOperation()) {
      return TabCreationOutcome::busy;
    }

    constexpr std::size_t maximum_label_bytes = 128;
    DisplayText16<maximum_label_bytes>::validate(label);
    const auto *tab = activeTab();
    const auto *pane = focusedPane();
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

  template <typename Request>
  void sendHistory(const Request &request) {
    try {
      transport_.send(request);
    } catch (const std::exception &error) {
      history_.fail(request.request_id, error.what());
      throw;
    }
  }

  void refreshHistoryDetails() {
    if (const auto request = history_.readCommand(nextRequest())) {
      sendHistory(*request);
    }

    if (const auto request = history_.readOutput(nextRequest())) {
      sendHistory(*request);
    }
  }

  void resolveHistoryScope(tbc::view<QueryHistory &, tbc::lt::a> request, HistoryScope scope) const {
    if (scope == HistoryScope::pane || scope == HistoryScope::cwd) {
      const auto *pane = focusedPane();
      if (pane == nullptr) {
        return;
      }

      if (scope == HistoryScope::pane) {
        request.scope = scope;
        request.scope_value = pane->id;
      } else if (!pane->cwd.empty()) {
        request.scope = scope;
        request.scope_value = std::string_view{pane->cwd};
      }
    } else if (scope == HistoryScope::workspace && active_tab_) {
      const auto location = active_tab_->workspace;
      const auto workspace = std::ranges::find_if(workspaces_, [&](const auto &entry) {
        return entry.location.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(entry.location, location);
      });
      if (workspace != workspaces_.end() && !workspace->path.empty()) {
        request.scope = scope;
        request.scope_value = std::string_view{workspace->path};
      }
    }
  }

  static bool equalSize(TerminalSize left, TerminalSize right) noexcept {
    return left.cols == right.cols && left.rows == right.rows && left.cell_width_px == right.cell_width_px && left.cell_height_px == right.cell_height_px;
  }

  std::uint64_t nextRequest() noexcept {
    return ++request_id_;
  }

  std::uint64_t pending(RequestKind kind, std::uint64_t pane_id = 0, ClientLayoutAxis axis = ClientLayoutAxis::horizontal) {
    if (pending_count_ == pending_.size()) {
      throw std::length_error{"Pending GUI request capacity reached"};
    }

    const auto request = nextRequest();
    pending_[pending_count_++] = {.id = request, .kind = kind, .pane_id = pane_id, .axis = axis};

    return request;
  }

  std::optional<Pending> complete(std::uint64_t request_id) noexcept {
    for (std::size_t index = 0; index < pending_count_; ++index) {
      if (pending_[index].id == request_id) {
        const auto result = pending_[index];
        pending_[index] = pending_[--pending_count_];

        return result;
      }
    }

    return {};
  }

  [[nodiscard]] Tab<Memory> *findTab(TabLocation location) const noexcept {
    const auto found = std::find_if(tabs_.begin(), tabs_.end(), [&](const auto &tab) {
      return sameTab(tab->location, location);
    });

    return found == tabs_.end() ? nullptr : found->get();
  }

  Tab<Memory> &ensureTab(TabLocation location) {
    if (auto *tab = findTab(location)) {
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

  Pane<Memory> &ensurePane(std::uint64_t pane_id, TabLocation location) {
    if (auto *pane = findPane(pane_id)) {
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

  void setPaneFocus(Tab<Memory> &tab, std::uint64_t pane_id) {
    if (tab.focused_pane != pane_id) {
      tab.focused_pane = pane_id;
      ++view_version_.panes;
    }

    graphics_pauses_.focus({.pane_id = pane_id, .now_ns = Clock::nowNanoseconds()}, [this](std::uint64_t paused_pane) {
      requestGraphicsSnapshot(paused_pane);
    });
  }

  void openDefault() {
    if (!presented_) {
      initial_open_pending_ = true;
      deferred_tab_.reset();

      return;
    }

    const auto launch = defaultLaunch();
    sendOpeningRequest(RequestKind::open_default, OpenPane{.size = launchSize(), .launch = launch});
  }

  [[nodiscard]] std::optional<MachineBookmark> machineBookmark() const noexcept {
    const auto *tab = activeTab();
    if (tab == nullptr) {
      return std::nullopt;
    }

    std::optional<std::uint64_t> fallback;
    if (tab->location.workspace.kind == WorkspaceLocation::Kind::workspace) {
      fallback = tab->location.workspace.id;
    } else if (const auto *row = workspaces_.worktree(tab->location.workspace.id)) {
      fallback = row->source;
    }

    return MachineBookmark{.location = tab->location, .pane_id = tab->focused_pane, .fallback_workspace = fallback};
  }

  bool recoverMissingWorkspacePane(const Pending &request, const RequestFailed &failure) {
    if ((request.kind != RequestKind::restore_machine && request.kind != RequestKind::visit_pane) || !request.fallback_workspace || failure.code != FailureCode::pane_not_found) {
      return false;
    }

    navigation_history_.forget({.kind = WorkspaceLocation::Kind::workspace, .id = *request.fallback_workspace});
    sendOpeningRequest(RequestKind::open_default, OpenPane{.target = {.kind = PaneTarget::Kind::workspace, .id = *request.fallback_workspace}, .size = launchSize()});

    return true;
  }

  void handoffPane(std::uint64_t pane_id, std::optional<std::uint64_t> fallback_workspace) {
    handoffWorkspace({.kind = PaneTarget::Kind::pane, .id = pane_id}, fallback_workspace);
  }

  void handoffWorkspace(PaneTarget target, std::optional<std::uint64_t> fallback_workspace) {
    const OpenPane opening{.target = target, .size = launchSize()};
    try {
      retainLayout();
      for (auto &pane : panes_) {
        if (pane->attached || pane->attaching) {
          prepareDetach(pane->id);
          transport_.send(DetachPane{pane->id});
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

  void releaseWorkspacePresentation() noexcept {
    const auto *tab = activeTab();
    if (tab != nullptr && findPane(tab->focused_pane) != nullptr) {
      navigation_history_.remember({.location = tab->location, .pane_id = tab->focused_pane, .layout = NavigationHistory::Layout{tab->layout, tab->focused_pane}, .fullscreen = tab->fullscreen});
    }

    for (const auto &known : tabs_) {
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
    path_picker_.close();
    suggestion_.invalidate();
    graphics_pauses_.reset();
    editor_opening_.reset();
    ++view_version_.workspace;
    ++view_version_.tabs;
    ++view_version_.active_tab;
    ++view_version_.panes;
    ++view_version_.host;
  }

  void restoreMachinePresentation() {
    if (active_tab_) {
      synchronizeAttachments();

      return;
    }

    if (std::ranges::any_of(std::span{pending_}.first(pending_count_), [](const Pending &request) {
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

  void openRestoredWorkspace(TabLocation location) {
    const auto saved = saved_layouts_.find(location);
    if (!saved) {
      throw EncodingError{"InvalidClientLayoutActiveTab"};
    }

    const auto fallback = location.workspace.kind == WorkspaceLocation::Kind::workspace ? std::optional{location.workspace.id} : std::nullopt;
    sendOpeningRequest(RequestKind::restore_machine, OpenPane{.target = {.kind = PaneTarget::Kind::pane, .id = saved->pane_id}, .size = launchSize()}, location, fallback);
  }

  void stageWorkspaceLayout(Tab<Memory> &tab) {
    pending_layout_restore_.reset();
    if (const auto saved = saved_layouts_.find(tab.location)) {
      pending_layout_restore_ = {.location = saved->location, .pane_id = saved->focused_pane, .layout = NavigationHistory::Layout{saved->nodes, saved->focused_pane}, .fullscreen = saved->fullscreen};
    } else if (const auto *bookmark = navigation_history_.find(tab.location.workspace); bookmark != nullptr && sameTab(bookmark->location, tab.location)) {
      pending_layout_restore_ = *bookmark;
    }

    tab.layout.restore({});
    tab.focused_pane = 0;
    tab.fullscreen = false;
    tab.loaded = false;
    tab.loading = false;
  }

  void restoreCanonicalLayout(Tab<Memory> &tab) {
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

  void createEditorTab(const EditorTarget &target) {
    EditorLaunch command;
    auto launch = defaultLaunch();
    launch.arguments = command.arguments(target.editor(), target.path(), target.line(), target.column());
    if (activeTab() != nullptr) {
      static_cast<void>(requestTabCreation({}, launch.arguments));
    } else {
      sendOpeningRequest(RequestKind::open_default, OpenPane{.size = launchSize(), .launch = launch});
    }
  }

  void splitEditorPane(const EditorRequest &request) {
    EditorLaunch command;
    auto launch = defaultLaunch();
    const auto &target = request.target;
    launch.arguments = command.arguments(target.editor(), target.path(), target.line(), target.column());
    if (!requestPaneSplit(request.source.pane_id, ClientLayoutAxis::horizontal, launch)) {
      throw std::runtime_error{"PaneSplitUnavailable"};
    }
  }

  void confirmAttachment(Pane<Memory> &pane) {
    if (pane.attached) {
      return;
    }

    if (attachment_generation_ == std::numeric_limits<std::uint64_t>::max()) {
      throw std::overflow_error{"AttachmentGenerationExhausted"};
    }

    pane.attachment_generation = ++attachment_generation_;
    pane.attached = true;
  }

  [[nodiscard]] Launch defaultLaunch() const noexcept {
    static constexpr std::array<std::string_view, 1> default_shell{"/bin/sh"};
    const auto arguments = launch_argument_count_ == 0 ? std::span<const std::string_view>{default_shell} : std::span<const std::string_view>{launch_arguments_}.first(launch_argument_count_);

    return {.cwd = launch_cwd_.empty() ? std::string_view{"/"} : std::string_view{launch_cwd_}, .arguments = arguments};
  }

  void synchronizeAttachments() {
    if (!presented_) {
      return;
    }

    acknowledgeFocusedAgent();
    const auto *active = activeTab();
    for (auto &pane : panes_) {
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
        transport_.send(DetachPane{pane->id});
        pane->attached = false;
        pane->acknowledged_frame = 0;
        pane->screen.detach();
        pane->graphics.detach();
      }
    }
  }

  void acknowledgeFocusedAgent() {
    if (!presented_) {
      return;
    }

    const auto *active = activeTab();
    if (active == nullptr) {
      return;
    }

    const auto agent = std::ranges::find_if(agents_, [&](const auto &candidate) {
      return candidate.pane_id == active->focused_pane && sameTab(candidate.location, active->location);
    });
    if (const auto request = agent_acknowledgement_.take(agent == agents_.end() ? nullptr : &*agent)) {
      transport_.send(*request);
    }
  }

  void prepareDetach(std::uint64_t pane_id) {
    if (copy_mode_.state() && copy_mode_.state()->pane_id == pane_id) {
      copy_mode_.reset();
      copy_search_request_ = 0;
    }

    if constexpr (requires { transport_.willDetach(pane_id); }) {
      transport_.willDetach(pane_id);
    }
  }

  Pane<Memory> *copyPane() noexcept {
    if (!copy_mode_.state()) {
      return nullptr;
    }

    auto *pane = findPane(copy_mode_.state()->pane_id);
    if (pane == nullptr || !pane->attached) {
      copy_mode_.reset();
      copy_search_request_ = 0;

      return nullptr;
    }

    return pane;
  }

  [[nodiscard]] CopyPointerAuthority pointerAuthority(const CopyPointerInput &input) const noexcept {
    if (const auto owner = copy_mode_.pointerOwner()) {
      const auto *pane = findPane(owner->pane_id);
      const auto available = pane != nullptr && pane->attached && pane->screen.columns() != 0 && pane->screen.rows() != 0;

      return {.kind = CopyPointerAuthority::Kind::selection, .dragging = owner->dragging, .position = available && input.pane_id == owner->pane_id ? std::optional{input.position} : std::nullopt};
    }

    const auto &state = copy_mode_.state();
    if (!state) {
      return {};
    }

    const auto *pane = findPane(state->pane_id);
    if (pane == nullptr || !pane->attached) {
      return {.kind = CopyPointerAuthority::Kind::missing};
    }

    return {.kind = CopyPointerAuthority::Kind::keyboard, .inside = input.pane_id == state->pane_id && input.inside};
  }

  void applyCopyPlan(const CopyPlan &plan, Pane<Memory> &pane) {
    if (!copy_mode_.current(plan) || plan.effect.open_link) {
      return;
    }

    if (plan.selection) {
      transport_.send(*plan.selection);
    }

    if (!copy_mode_.commit(plan)) {
      return;
    }

    if (plan.viewport) {
      if (pane.screen.scroll().offset != plan.viewport->offset) {
        ++view_version_.viewport;
      }

      pane.screen.setViewport(plan.viewport->offset);
      ++pane.viewport_requests;
      transport_.send(*plan.viewport);
    }
  }

  void applyPointerMotion(const CopyPointerDecision &decision, bool released, Pane<Memory> &pane) {
    const auto grid = copyGrid(pane.screen);
    std::optional<CopyPlan> plan;
    if (decision.motion) {
      plan = copy_mode_.pointer(*decision.motion, grid, released);
    } else if (decision.vertical) {
      plan = copy_mode_.vertical(*decision.vertical, grid);
    }

    if (plan) {
      applyCopyPlan(*plan, pane);
    }
  }

  Change apply(const PaneMatches &message) {
    const auto &state = copy_mode_.state();
    if (message.request_id != copy_search_request_ || !state || state->pointer || message.pane_id != state->pane_id) {
      return Change::none;
    }

    auto *pane = copyPane();
    if (pane == nullptr) {
      return Change::none;
    }

    const auto plan = copy_mode_.search(message.matches, copyGrid(pane->screen), copy_search_origin_);
    if (plan) {
      applyCopyPlan(*plan, *pane);
    }
    copy_search_truncated_ = message.truncated;

    copy_search_request_ = 0;
    changed_pane_ = pane->id;

    return Change::copy_mode;
  }

  Change apply(const PaneFrame &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr || !pane->attached) {
      return Change::none;
    }

    const auto previous_offset = pane->screen.scroll().offset;
    const auto outcome = pane->screen.apply(message);
    if (outcome == FrameApplication::needs_snapshot && !pane->snapshot_requested) {
      pane->snapshot_requested = true;
      transport_.send(RequestSnapshot{message.pane_id, pane->screen.frameId()});
    }

    if (outcome == FrameApplication::applied) {
      if (copy_mode_.state() && copy_mode_.state()->pane_id == pane->id) {
        copy_mode_.onFrame(previous_offset, copyGrid(pane->screen));
      }
      if (const auto island = islands_.find(pane->id); island != islands_.end()) {
        island->second.output = Clock::nowNanoseconds();
      }

      pane->snapshot_requested = false;
      if (const auto prompt = livePromptRow(*pane)) {
        pane->live_prompt_row = prompt;
      }
      if (!pane->folded.empty()) {
        refreshFolds(*pane);
      }
      changed_pane_ = pane->id;

      return Change::terminal;
    }

    return Change::none;
  }

  // The rows the folded blocks hide, from their stable numbers; folds whose blocks are gone
  // are forgotten.
  inline void refreshFolds(Pane<Memory> &pane) {
    if (pane.folded.empty()) {
      if (!pane.folds.empty()) {
        pane.folds.clear();
        ++pane.fold_revision;
      }
      return;
    }
    std::vector<typename FoldMap<>::Span> spans;
    std::vector<std::uint64_t> kept;
    for (std::size_t index = 0; index < pane.blocks.size(); ++index) {
      if (std::ranges::find(pane.folded, blockKey(pane, index)) == pane.folded.end()) {
        continue;
      }
      kept.push_back(blockKey(pane, index));
      const auto [first, end] = blockRows(pane, index);
      if (end > first) {
        spans.push_back({.first = first, .count = end - first});
      }
    }
    pane.folded = std::move(kept);
    if (!std::ranges::equal(pane.folds.spans(), spans)) {
      pane.folds.assign(spans);
      ++pane.fold_revision;
    }
  }

  template <typename Message, ClientCommandHandler Handler>
  Change dispatchMessage(std::span<const Byte> payload, DecodeStorage &storage, Handler &handler) {
    if constexpr (std::same_as<Message, GraphicsSnapshot> || std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsSharedImage> || std::same_as<Message, GraphicsImageChunk> || std::same_as<Message, GraphicsPlacementMessage> || std::same_as<Message, GraphicsDeleteImage> || std::same_as<Message, GraphicsDeletePlacement>) {
      try {
        const auto change = apply(Codec::decode<Message>(payload, storage));
        resumeGraphics();

        return change;
      } catch (const std::exception &error) {
        recoverRuntime(error.what());

        throw;
      }
    } else if constexpr (std::same_as<Message, ClientCommand>) {
      return apply(Codec::decode<Message>(payload, storage), handler);
    } else {
      return apply(Codec::decode<Message>(payload, storage));
    }
  }

  template <typename Message, typename Source = std::nullptr_t>
  Change applyGraphics(const Message &message, Source source = nullptr) {
    auto *pane = findPane(message.header.pane_id);
    if (pane == nullptr || !pane->attached) {
      return Change::none;
    }

    bool changed = false;
    try {
      if constexpr (std::same_as<Message, GraphicsSnapshot>) {
        changed = pane->graphics.snapshot(message);
        if (changed) {
          graphics_pauses_.snapshotApplied(pane->id, message.phase, Clock::nowNanoseconds());
        }
      } else if constexpr (std::same_as<Message, GraphicsImage>) {
        changed = pane->graphics.image(message);
      } else if constexpr (std::same_as<Message, GraphicsSharedImage>) {
        changed = pane->graphics.sharedImage(message, source);
      } else if constexpr (std::same_as<Message, GraphicsImageChunk>) {
        changed = pane->graphics.chunk(message);
      } else if constexpr (std::same_as<Message, GraphicsPlacementMessage>) {
        changed = pane->graphics.placement(message);
      } else {
        changed = pane->graphics.erase(message);
      }
    } catch (const GraphicsLimitError &error) {
      pauseGraphics(pane->id, error);
    } catch (const GraphicsResyncRequired &) {
      requestGraphicsSnapshot(pane->id);
    }

    const auto credit = pane->graphics.takeCredit();
    if (credit != 0) {
      sendGraphics(GraphicsCredit{pane->id, credit});
    }

    changed_pane_ = pane->id;

    return changed ? Change::terminal : Change::none;
  }

  void recoverRuntime(std::string_view reason) {
    if (!ready_) {
      return;
    }

    ready_ = false;
    if constexpr (requires { transport_.recover(reason); }) {
      transport_.recover(reason);
    }
  }

  template <typename Message>
  void sendGraphics(const Message &message) {
    try {
      transport_.send(message);
    } catch (const std::exception &error) {
      recoverRuntime(error.what());

      throw;
    }
  }

  void requestGraphicsSnapshot(std::uint64_t pane_id) {
    sendGraphics(RequestGraphicsSnapshot{pane_id});
  }

  LimitReports::Recorded countLimitReach(LimitReach reach) {
    const auto awake_ms = static_cast<std::int64_t>(Clock::nowNanoseconds() / NotificationInput::nanoseconds_per_millisecond);
    const LimitReports::Time sampled{.awake_ms = awake_ms, .real_ms = runtime::ObservationTime::now().milliseconds};
    const auto recorded = limit_reports_.record(reach, sampled, 1);
    if (const auto hits = limit_reports_.takeReport(recorded.slot, awake_ms)) {
      const ReportLimit report{.reach = limit_reports_.row(recorded.slot).reach(), .hits = *hits};
      bool delivered = false;
      try {
        if constexpr (requires { { transport_.report(report) } -> std::same_as<bool>; }) {
          delivered = transport_.report(report);
        } else {
          transport_.send(report);
          delivered = true;
        }
      } catch (const std::exception &) {
        delivered = false;
      }

      if (!delivered) {
        limit_reports_.restoreReport(recorded.slot, *hits);
      }
    }

    return recorded;
  }

  void pauseGraphics(std::uint64_t pane_id, const GraphicsLimitError &error) {
    const auto slot = countLimitReach({.name = error.what(), .route = "runtime_message"}).slot;
    graphics_pauses_.pause(pane_id, Clock::nowNanoseconds(), [this](std::uint64_t paused_pane) {
      requestGraphicsSnapshot(paused_pane);
    },
                           [this, slot](std::uint64_t paused_pane) {
                             showGraphicsPause(slot, paused_pane);
                           });
  }

  void showGraphicsPause(LimitReports::Slot slot, std::uint64_t pane_id) {
    const auto &row = limit_reports_.row(slot);
    const auto message = LimitReports::describe(row.reach(), row.hits);
    const auto title = graphicsPauseTitle(pane_id);
    publishNotification({.level = NotificationLevel::warning, .target = {.kind = NotificationTarget::Kind::pane, .id = pane_id}, .title = title.view(), .message = message.view(), .link = {}, .duration_ns = limit_notice_duration_ns});
  }

  [[nodiscard]] BoundedText<max_notification_title_bytes> graphicsPauseTitle(std::uint64_t pane_id) const {
    BoundedText<max_notification_title_bytes> title;
    title.append("Images paused");
    const auto *pane = findPane(pane_id);
    const auto *tab = pane == nullptr ? nullptr : findTab(pane->location);
    const auto index = tab == nullptr ? 0 : tab->layout.displayIndex(pane_id);
    if (index != 0) {
      const std::string_view foreground{pane->foreground};
      const auto name = !foreground.empty() && inspectUtf8(foreground) == Utf8Validation::valid ? foreground : "shell";
      title.append(" in pane ");
      title.appendDecimal(static_cast<std::uint16_t>(index));
      title.append(": ");
      title.append(name);
    }

    return title;
  }

  void forgetClosedGraphics() {
    graphics_pauses_.forgetClosed([this](std::uint64_t pane_id) {
      return findPane(pane_id) != nullptr;
    });
  }

  Change apply(const GraphicsSnapshot &message) {
    return applyGraphics(message);
  }

  Change apply(const GraphicsImage &message) {
    return applyGraphics(message);
  }

  [[nodiscard]] bool supportsSharedGraphics() const noexcept {
    if constexpr (requires { transport_.supportsSharedMemory(); }) {
      return transport_.supportsSharedMemory();
    }

    return false;
  }

  Change apply(const GraphicsSharedImage &message) {
    if constexpr (requires { transport_.sharedImage(message.name); }) {
      if (supportsSharedGraphics()) {
        return applyGraphics(message, transport_.sharedImage(message.name));
      }
    }

    throw EncodingError{"Shared graphics was not negotiated"};
  }

  Change apply(const GraphicsImageChunk &message) {
    return applyGraphics(message);
  }

  Change apply(const GraphicsPlacementMessage &message) {
    return applyGraphics(message);
  }

  Change apply(const GraphicsDeleteImage &message) {
    return applyGraphics(message);
  }

  Change apply(const GraphicsDeletePlacement &message) {
    return applyGraphics(message);
  }

  Change apply(const PaneOpened &message) {
    const auto request = complete(message.request_id);
    if (!request) {
      if (findPane(message.pane_id) == nullptr) {
        transport_.send(DetachPane{message.pane_id});
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
    auto &pane = ensurePane(message.pane_id, message.location);
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
    auto &tab = ensureTab(message.location);
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

  Change apply(const TabCreated &message) {
    const auto request = complete(message.request_id);
    const auto *previous = activeTab();
    if (!request || request->kind != RequestKind::create_tab || !sameWorkspace(request->location.workspace, message.location.workspace) || previous == nullptr || !sameWorkspace(previous->location.workspace, message.location.workspace)) {
      throw EncodingError{"UnexpectedTabCreated"};
    }

    const auto cached = std::ranges::find_if(tabs_, [&](const auto &tab) {
      return sameTab(tab->location, message.location);
    });
    const bool discovered = cached != tabs_.end();
    if ((discovered && ((*cached)->loaded || (*cached)->loading || !(*cached)->layout.nodes().empty())) || findPane(message.root_pane_id) != nullptr) {
      throw EncodingError{"Tab or pane already exists"};
    }

    const auto cached_index = static_cast<std::size_t>(cached - tabs_.begin());
    const auto count = static_cast<std::size_t>(std::ranges::count_if(tabs_, [&](const auto &tab) {
                         return sameWorkspace(tab->location.workspace, message.location.workspace);
                       })) -
                       static_cast<std::size_t>(discovered);
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
      for (auto &existing : tabs_) {
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

  Change apply(const TabSnapshot &message) {
    completeRequest(RequestKind::tab_snapshot, message.request_id);
    if (!presented_ && !leave_pending_) {
      return Change::none;
    }

    auto &tab = ensureTab(message.location);
    restoreCanonicalLayout(tab);
    tab.loaded = true;
    tab.loading = false;
    std::array<std::uint64_t, PaneLayout::maximum_panes> removed{};
    std::size_t removed_count = 0;
    for (const auto &node : tab.layout.nodes()) {
      const auto *leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf != nullptr && std::none_of(message.panes.begin(), message.panes.end(), [&](const auto &pane) {
            return pane.pane_id == leaf->pane_id;
          })) {
        removed[removed_count++] = leaf->pane_id;
      }
    }

    for (const auto identity : std::span{removed}.first(removed_count)) {
      tab.layout.remove(identity);
      ++view_version_.panes;
    }

    for (const auto &descriptor : message.panes) {
      auto &pane = ensurePane(descriptor.pane_id, message.location);
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
    std::erase_if(panes_, [&](const auto &pane) {
      return sameTab(pane->location, message.location) && !tab.layout.contains(pane->id);
    });
    forgetClosedGraphics();

    return Change::model;
  }

  Change apply(const WorkspaceSnapshot &message) {
    const bool current_workspace = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);
    completeRequest(RequestKind::workspace_snapshot, message.request_id);
    std::array<TabLocation, maximum_tabs> removed;
    std::size_t removed_count = 0;
    for (const auto &tab : tabs_) {
      if (sameWorkspace(tab->location.workspace, message.workspace) && std::none_of(message.tabs.begin(), message.tabs.end(), [&](const auto &entry) {
            return entry.tab_id == tab->location.tab_id;
          })) {
        removed[removed_count++] = tab->location;
      }
    }

    for (const auto &location : std::span{removed}.first(removed_count)) {
      discardTab(location);
    }

    for (auto &workspace : workspaces_) {
      if (sameWorkspace(workspace.location, message.workspace)) {
        if (workspace.name != message.name) {
          ++view_version_.workspace;
        }

        workspace.name = message.name;
      }
    }

    for (const auto &descriptor : message.tabs) {
      auto &tab = ensureTab({message.workspace, descriptor.tab_id});
      if (tab.label != descriptor.label || tab.position != descriptor.position) {
        ++view_version_.tabs;
      }

      tab.label = descriptor.label;
      tab.position = descriptor.position;
      tab.observePanes(descriptor.panes);
    }

    if (current_workspace && !active_tab_ && (presented_ || leave_pending_) && !message.tabs.empty()) {
      selectTab({message.workspace, message.tabs.front().tab_id});
    }

    return Change::model;
  }

  Change apply(const WorkspaceList &message) {
    return workspaces_.apply(message) ? Change::model : Change::none;
  }

  Change apply(const ClientLayoutSnapshot &message) {
    if (active_tab_) {
      if (auto const *tab = activeTab()) {
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
    for (const auto &saved : message.tabs) {
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

    return Change::configuration;
  }

  Change apply(const TabClosed &message) {
    complete(message.request_id);
    const auto active_closed = active_tab_ && sameTab(*active_tab_, message.location);
    const auto *closing = findTab(message.location);
    const bool closing_known = closing != nullptr;
    const auto position = closing_known ? closing->position : std::uint16_t{};
    const auto replacement = tabAfterRemoval(message.location, position);
    discardTab(message.location);
    if (closing_known) {
      for (auto &tab : tabs_) {
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

  [[nodiscard]] std::optional<TabLocation> tabAfterRemoval(TabLocation closing, std::uint16_t position) const noexcept {
    const Tab<Memory> *previous = nullptr;
    const Tab<Memory> *next = nullptr;
    for (const auto &tab : tabs_) {
      if (!sameWorkspace(tab->location.workspace, closing.workspace) || sameTab(tab->location, closing)) {
        continue;
      }

      if (tab->position > position && (next == nullptr || tab->position < next->position)) {
        next = tab.get();
      } else if (tab->position < position && (previous == nullptr || tab->position > previous->position)) {
        previous = tab.get();
      }
    }

    const auto *selected = next == nullptr ? previous : next;

    return selected == nullptr ? std::nullopt : std::optional{selected->location};
  }

  void discardTab(TabLocation location) {
    if (findTab(location) != nullptr) {
      ++view_version_.tabs;
      ++view_version_.panes;
    }

    for (const auto &pane : panes_) {
      if (!sameTab(pane->location, location)) {
        continue;
      }

      if (pane->attached) {
        prepareDetach(pane->id);
        transport_.send(DetachPane{pane->id});
      }

      cancelPaneRequests(pane->id);
      if (copy_mode_.state() && copy_mode_.state()->pane_id == pane->id) {
        copy_mode_.reset();
        copy_search_request_ = 0;
      }
    }

    std::erase_if(tabs_, [&](const auto &tab) {
      return sameTab(tab->location, location);
    });
    std::erase_if(panes_, [&](const auto &pane) {
      return sameTab(pane->location, location);
    });
    forgetClosedGraphics();
    if (active_tab_ && sameTab(*active_tab_, location)) {
      active_tab_.reset();
    }
  }

  void cancelPaneRequests(std::uint64_t pane_id) noexcept {
    for (std::size_t index = pending_count_; index-- > 0;) {
      if (pending_[index].pane_id == pane_id && pending_[index].kind != RequestKind::split) {
        complete(pending_[index].id);
      }
    }
  }

  Change apply(const TabRenamed &message) {
    const auto request = complete(message.request_id);
    if (!request || request->kind != RequestKind::rename_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabRenamed"};
    }

    if (auto *tab = findTab(message.location)) {
      if (tab->label != message.label) {
        ++view_version_.tabs;
      }

      tab->label = message.label;
    }

    return Change::model;
  }

  Change apply(const TabMoved &message) {
    const auto request = complete(message.request_id);
    if (!request || request->kind != RequestKind::move_tab || !sameTab(request->location, message.location)) {
      throw EncodingError{"UnexpectedTabMoved"};
    }

    if (auto *tab = findTab(message.location)) {
      const auto count = std::ranges::count_if(tabs_, [&](const auto &entry) {
        return sameWorkspace(entry->location.workspace, message.location.workspace);
      });
      if (message.position >= count) {
        throw EncodingError{"Invalid tab position"};
      }

      const auto previous = tab->position;
      for (auto &entry : tabs_) {
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

  Change apply(const PaneExited &message) {
    if (auto *pane = findPane(message.pane_id)) {
      pane->exited = true;
      ++view_version_.panes;
    }

    for (auto &tab : tabs_) {
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
    std::erase_if(panes_, [&](const auto &pane) {
      return pane->id == message.pane_id;
    });
    forgetClosedGraphics();

    return Change::model;
  }

  Change apply(const PaneTitle &message) {
    if (auto *pane = findPane(message.pane_id)) {
      pane->title = message.title;
    }

    return Change::model;
  }

  Change apply(const PaneCwd &message) {
    if (auto *pane = findPane(message.pane_id)) {
      pane->cwd = message.cwd;
    }

    return Change::model;
  }

  Change apply(const PaneForeground &message) {
    if (auto *pane = findPane(message.pane_id)) {
      pane->foreground = message.name;
    }

    for (const auto &tab : tabs_) {
      tab->observeForeground(message);
    }

    return Change::model;
  }

  Change apply(const PaneClipboard &message) {
    clipboard_ = textView(message.bytes);

    return Change::clipboard;
  }

  Change apply(const PaneProgress &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr || (pane->progress_state == message.state && pane->progress_percent == message.percent)) {
      return Change::none;
    }

    pane->progress_state = message.state;
    pane->progress_percent = message.percent;

    return Change::model;
  }

  Change apply(const PaneGit &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr || pane->git == message) {
      return Change::none;
    }

    pane->git_branch.assign(message.branch);
    pane->git = message;
    pane->git.branch = pane->git_branch;
    changed_pane_ = pane->id;
    return Change::model;
  }

  Change apply(const PaneShell &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr || pane->shell == message) {
      return Change::none;
    }

    const auto previous_host = pane->shell_host;
    const auto previous = std::exchange(pane->shell, message);
    pane->shell_host.assign(message.host);
    pane->shell.host = pane->shell_host;
    pane->shell_directory.assign(message.directory);
    pane->shell.directory = pane->shell_directory;
    // The pane's header names the host and the link.
    chrome_changed_ |= previous.remote != message.remote || previous_host != pane->shell_host || previous.link_ms != message.link_ms;
    if (const auto found = islands_.find(pane->id); found != islands_.end()) {
      auto &island = found->second.island;
      if (message.phase != ShellPhase::running || message.echo) {
        island.clearSecret();
      }
      if (previous.phase == ShellPhase::running && message.phase == ShellPhase::prompt) {
        deliverPrompt(pane->id, island.promptReturned(message.commands != previous.commands && message.status == 0), island);
      }
    }
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change apply(const CommandSpec &message) {
    const auto request = spec_requests_.find(message.request_id);
    if (request == spec_requests_.end()) {
      return Change::none;
    }
    const auto [pane_id, command] = std::move(request->second);
    spec_requests_.erase(request);
    // An alias's spec is the one of the command it stands for, kept under that command's name.
    const auto expansion = message.command == command ? message.expansion : std::string_view{};
    const auto target = expansion.empty() ? std::string_view{command} : expansion.substr(0, expansion.find(' '));
    auto state = SpecState::unavailable;
    if (message.state == CommandSpecState::available && message.command == command) {
      state = prompt_specs_.install(target, message.digest, message.source) ? SpecState::available : SpecState::unavailable;
    } else if (message.state == CommandSpecState::unchanged && prompt_specs_.find(target) != nullptr && prompt_specs_.digest(target) == message.digest) {
      state = SpecState::available;
    }
    auto &checks = command_checks_[pane_id];
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      known->second = state;
    }
    if (state == SpecState::available && !expansion.empty()) {
      checks.aliases.insert_or_assign(command, std::string{expansion});
      if (checks.alias_targets.size() >= 256) {
        checks.alias_targets.clear();
      }
      checks.alias_targets.insert_or_assign(command, std::string{target});
    }
    // A Tab that waited for it completes now, if the line is still the one it was for.
    const auto waiting = spec_completions_.find(pane_id);
    const auto island = islands_.find(pane_id);
    const auto *pane = findPane(pane_id);
    if (waiting == spec_completions_.end() || island == islands_.end() || pane == nullptr) {
      return Change::none;
    }
    const bool same = waiting->second == island->second.island.editor().text().view();
    spec_completions_.erase(waiting);
    if (!same) {
      return Change::none;
    }
    beginCompletion(pane_id, island->second.island, shell::Syntax{.dialect = pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix});
    changed_pane_ = pane_id;
    return Change::terminal;
  }

  Change apply(const PaneBlocks &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    std::size_t bytes = 0;
    for (const auto &block : message.blocks) {
      bytes += block.command.size();
    }
    pane->blocks_text.clear();
    pane->blocks_text.reserve(bytes);
    pane->blocks.assign(message.blocks.begin(), message.blocks.end());
    for (auto &block : pane->blocks) {
      const auto start = pane->blocks_text.size();
      pane->blocks_text.append(block.command);
      block.command = std::string_view{pane->blocks_text}.substr(start, block.command.size());
    }
    // A command that ran without the shell finding it missing (status 127) exists, though the
    // shell never reported it: a function defined since its last report, say.
    if (!pane->blocks.empty() && !pane->shell.remote) {
      const auto &last = pane->blocks.back();
      if ((last.state == CommandBlockState::succeeded || last.state == CommandBlockState::failed) && last.status != 127) {
        learnCommand(pane->id, last.command, pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix);
      }
    }
    if (!pane->refold.empty()) {
      for (const auto index : pane->refold) {
        if (index < pane->blocks.size()) {
          pane->folded.push_back(blockKey(*pane, index));
        }
      }
      pane->refold.clear();
    }
    refreshFolds(*pane);
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change apply(const PaneScrollback &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    if (pane->scrollback_generation == message.generation && message.trimmed > pane->scrollback_trimmed) {
      // The blocks come again with their rows moved up; until then they are moved here, so
      // their folds keep hiding the same rows.
      const auto dropped = message.trimmed - pane->scrollback_trimmed;
      pane->scrollback_dropped += dropped;
      std::erase_if(pane->blocks, [dropped](const CommandBlock &block) { return block.row < dropped; });
      for (auto &block : pane->blocks) {
        block.row -= static_cast<std::uint32_t>(dropped);
      }
      if (pane->live_prompt_row) {
        pane->live_prompt_row = *pane->live_prompt_row >= dropped ? std::optional{static_cast<std::uint32_t>(*pane->live_prompt_row - dropped)} : std::nullopt;
      }
    } else if (pane->scrollback_generation != 0 && pane->scrollback_generation != message.generation && !pane->folded.empty()) {
      // Renumbered rows: the blocks come again with their new rows, and their folds follow them
      // by order then.
      pane->refold.clear();
      for (std::size_t index = 0; index < pane->blocks.size(); ++index) {
        if (std::ranges::find(pane->folded, blockKey(*pane, index)) != pane->folded.end()) {
          pane->refold.push_back(index);
        }
      }
      pane->folded.clear();
    }
    if (pane->scrollback_generation != message.generation) {
      pane->live_prompt_row.reset();
    }
    pane->scrollback_generation = message.generation;
    pane->scrollback_trimmed = message.trimmed;
    pane->rows.number(message.generation);
    refreshFolds(*pane);
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change apply(const PaneRows &message) {
    auto *pane = findPane(message.pane_id);
    if (pane == nullptr) {
      return Change::none;
    }

    if (!pane->rows.store(message, pane->screen.columns())) {
      return Change::none;
    }
    changed_pane_ = pane->id;
    return Change::terminal;
  }

  Change apply(const AgentSnapshot &message) {
    const auto now_ns = Clock::nowNanoseconds();
    if (!agents_.apply(message, now_ns)) {
      return Change::none;
    }

    if (peek_.target()) {
      if (peekAgent() == nullptr) {
        closePeek();
      } else {
        requestPeekScreen();
      }
    }

    acknowledgeFocusedAgent();
    AgentAlerts::publish(agents_.statusChanges(), [&](const AgentStatusChange &change) {
      const auto agent = std::ranges::find_if(agents_, [&](const auto &candidate) {
        return candidate.pane_id == change.pane_id && candidate.pane_generation == change.pane_generation;
      });

      return agent == agents_.end() ? AgentCardLabels::generic_name : AgentCardLabels::title({}, agent->display_name);
    },
                         [&](NotificationInput input) {
                           publishNotificationAt(input, now_ns);
                         });

    return Change::model;
  }

  Change apply(const PaneList &message) {
    return pane_list_.apply(message, Clock::nowNanoseconds()) ? Change::model : Change::none;
  }

  Change apply(const HistoryResults &message) {
    if (message.request_id == prompt_history_request_ && prompt_history_request_ != 0) {
      prompt_history_request_ = 0;
      prompt_history_.clear();
      for (const auto &entry : message.entries) {
        if (!entry.command_truncated && !entry.command.empty()) {
          prompt_history_.emplace_back(entry.command);
        }
      }
      return Change::none;
    }
    if (!history_.apply(message)) {
      return Change::none;
    }

    refreshHistoryDetails();

    return Change::history;
  }

  Change apply(const HistoryOutput &message) {
    return history_.apply(message) ? Change::history : Change::none;
  }

  Change apply(const HistoryPruned &message) {
    if (!history_.apply(message)) {
      return Change::none;
    }

    sendHistory(history_.refresh(nextRequest()));

    return Change::history;
  }

  Change apply(const CompletionWords &message) {
    if (const auto checked = command_requests_.find(message.request_id); checked != command_requests_.end()) {
      const auto found = std::ranges::any_of(message.words, [&](const CompletionWord &word) { return word.text == checked->second.word; });
      return settleCommand(checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown : CommandPresence::missing);
    }
    const auto pending = path_completions_.find(message.request_id);
    if (pending == path_completions_.end()) {
      return Change::none;
    }
    const auto [pane_id, base, query] = std::move(pending->second);
    path_completions_.erase(pending);
    const auto island = islands_.find(pane_id);
    if (island == islands_.end()) {
      return Change::none;
    }
    std::vector<prompt::Choice> words;
    for (const auto &word : message.words) {
      words.push_back({.text = base + std::string{word.text}, .description = std::string{word.description}});
    }
    island->second.island.receive(message.request_id, words, message.truncated);
    changed_pane_ = pane_id;
    return Change::terminal;
  }

  Change apply(const PathResults &message) {
    if (const auto checked = command_requests_.find(message.request_id); checked != command_requests_.end()) {
      const auto name = std::string_view{checked->second.word}.substr(checked->second.word.rfind('/') + 1);
      const auto found = std::ranges::any_of(message.matches, [&](const PathMatch &match) { return match.kind != PathKind::directory && match.path == name; });
      return settleCommand(checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown : CommandPresence::missing);
    }
    if (const auto pending = path_completions_.find(message.request_id); pending != path_completions_.end()) {
      const auto [pane_id, base, query] = std::move(pending->second);
      path_completions_.erase(pending);
      if (const auto island = islands_.find(pane_id); island != islands_.end()) {
        // The shell completes one directory at a time: children of the root that start with
        // what was typed, not the deeper matches the search also finds.
        std::vector<prompt::Choice> paths;
        for (const auto &match : message.matches) {
          // Directories arrive with their trailing slash.
          const bool directory = match.kind == PathKind::directory;
          const auto name = directory ? match.path.substr(0, match.path.size() - 1) : match.path;
          if (name.find('/') == std::string_view::npos && name.starts_with(query)) {
            paths.push_back({.text = base + std::string{match.path}, .directory = directory});
          }
        }
        island->second.island.receive(message.request_id, paths, message.truncated);
        changed_pane_ = pane_id;
        return Change::terminal;
      }
      return Change::none;
    }
    return path_picker_.receive(message) ? Change::paths : Change::none;
  }

  Change apply(const CommandSuggestion &message) {
    return suggestion_.receive(message) ? Change::suggestion : Change::none;
  }

  Change apply(const SystemMetrics &message) {
    return metrics_.update(message) ? Change::metrics : Change::none;
  }

  Change apply(const ProxyStatus &message) {
    proxy_ = message;
    return Change::model;
  }

  Change apply(const RequestFailed &message) {
    for (auto &pane : panes_) {
      if (pane->rows.settle(message.request_id)) {
        return Change::none;
      }
    }

    const auto paths_revision = path_picker_.revision();
    if (path_picker_.fail(message)) {
      return paths_revision != path_picker_.revision() ? Change::paths : Change::none;
    }

    if (history_.owns(message.request_id)) {
      return history_.fail(message.request_id, message.message) ? Change::history : Change::none;
    }

    if (editor_opening_.complete(message.request_id)) {
      return reportLinkFailure(message.message);
    }

    if (const auto request = complete(message.request_id)) {
      if (const auto change = failPeekRequest(*request, message)) {
        return *change;
      }

      if (recoverMissingWorkspacePane(*request, message)) {
        return Change::model;
      }

      if (request->kind == RequestKind::forget_worktree) {
        return Change::none;
      }

      if (request->kind == RequestKind::attach) {
        if (auto *pane = findPane(request->pane_id)) {
          pane->attaching = false;
        }
      } else if (request->kind == RequestKind::tab_snapshot) {
        if (auto *tab = findTab(request->location)) {
          tab->loading = false;
        }
      } else if (request->kind == RequestKind::split) {
        recoverSplit(*request);
      }
    }

    error_ = message.message;

    return Change::model;
  }

  Change apply(const EditorOpened &message) {
    const auto request = editor_opening_.complete(message.request_id);
    if (!request) {
      return Change::none;
    }

    const auto &source = request->source;
    const auto *pane = findPane(source.pane_id);
    if (pane == nullptr || !active_tab_ || !sameTab(source.location, *active_tab_) || !sameTab(pane->location, source.location) || pane->generation != source.pane_generation || pane->attachment_generation != source.attachment_generation) {
      return Change::none;
    }

    switch (message.outcome) {
    case EditorOutcome::unavailable:
      try {
        splitEditorPane(*request);
      } catch (const std::exception &error) {
        return reportLinkFailure(error.what());
      }

      return Change::model;
    case EditorOutcome::failed:
      return reportLinkFailure("EditorOpenFailed");
    case EditorOutcome::missing:
      return reportLinkFailure("FileNotFound");
    case EditorOutcome::opened: {
      const auto *editor = findPane(message.pane_id);
      if (editor == nullptr || !sameTab(editor->location, source.location) || editor->generation != message.pane_generation) {
        return Change::none;
      }

      focusPane(editor->id);

      return Change::model;
    }
    }

    return Change::none;
  }

  Change reportLinkFailure(std::string_view message) {
    notice_ = "Could not open link: ";
    notice_ += message;
    publishNotification({.level = NotificationLevel::failure, .title = "Could not open link", .message = message, .link = {}});

    return Change::notification;
  }

  Change apply(const RequestCompleted &message) {
    const auto request = complete(message.request_id);
    if (request && request->kind == RequestKind::forget_worktree) {
      return Change::none;
    }

    if (request && request->kind == RequestKind::close_pane) {
      ++view_version_.panes;
      for (auto &tab : tabs_) {
        tab->layout.remove(request->pane_id);
        if (tab->focused_pane == request->pane_id) {
          tab->focused_pane = tab->layout.firstPane();
        }
      }

      synchronizeAttachments();
      retainLayout();
    }

    return Change::model;
  }

  Change apply(const PaneText &message) {
    if (!completeRequest(RequestKind::peek_screen, message.request_id)) {
      return Change::none;
    }

    const auto dropped = peek_.store(message);
    if (!dropped) {
      return Change::none;
    }

    if (*dropped != 0) {
      reportLimit({.name = "peek.text_bytes", .noun = "bytes", .value = PeekLimits::text_bytes, .requested = message.text.size()});
    }

    return Change::peek;
  }

  Change apply(const ResyncRequired &message) {
    if (message.workspace_closed) {
      const auto active_closed = active_tab_ && sameWorkspace(active_tab_->workspace, message.workspace);
      std::array<TabLocation, maximum_tabs> removed;
      std::size_t removed_count = 0;
      for (const auto &tab : tabs_) {
        if (sameWorkspace(tab->location.workspace, message.workspace)) {
          removed[removed_count++] = tab->location;
        }
      }

      for (const auto &location : std::span{removed}.first(removed_count)) {
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

    for (const auto &pane : panes_) {
      if (pane->attached) {
        transport_.send(RequestSnapshot{pane->id, pane->screen.frameId()});
      }
    }

    return Change::model;
  }

  Change apply(const Notification &message) {
    notice_ = message.title;
    if (!message.message.empty()) {
      notice_ += ": ";
      notice_ += message.message;
    }

    publishNotification({.level = message.level, .target = message.target, .title = message.title, .message = message.message, .link = message.link, .duration_ns = static_cast<std::uint64_t>(message.duration_ms) * NotificationInput::nanoseconds_per_millisecond});

    return Change::notification;
  }

  void publishNotificationAt(NotificationInput input, std::uint64_t now_ns) {
    notifications_.push(now_ns, input);
    ++notification_revision_;

    static_cast<void>(deliverHostNotification(input));
  }

  [[nodiscard]] bool deliverHostNotification(const NotificationInput &input) noexcept {
    if (configuration_.notification_delivery != NotificationDelivery::system) {
      return false;
    }

    try {
      return effects_.postNotification(NotificationPayload::create(input.title, input.message));
    } catch (...) {
      return false;
    }
  }

  Change apply(const AgentSoundNotification &message) {
    const auto current = std::ranges::any_of(agents_, [&](const auto &agent) {
      return agent.pane_id == message.pane_id && agent.pane_generation == message.pane_generation;
    });
    if (current) {
      const auto outcome = sound_playback_.request(message.sound);
      if (outcome.state == SoundRequestOutcome::State::start) {
        startAgentSound(outcome.sound);
      }
    }

    return Change::none;
  }

  void startAgentSound(AgentSound sound) {
    try {
      if (!effects_.playSound(sound)) {
        sound_playback_.schedulingFailed();
      }
    } catch (...) {
      sound_playback_.schedulingFailed();
      throw;
    }
  }

  Change apply([[maybe_unused]] const RuntimeStopping &message) {
    disconnected();

    return Change::stopped;
  }

  template <ClientCommandHandler Handler>
  Change apply(const ClientCommand &message, Handler &handler) {
    CompleteClientCommand reply;
    static_cast<ClientCommand &>(reply) = message;
    // The reply starts as the command, text included: the actions
    // whose text is only a request argument clear it.
    reply.status = ClientCommandStatus::applied;
    auto change = Change::model;

    try {
      if (message.status != ClientCommandStatus::request) {
        throw EncodingError{"Invalid routed command status"};
      }

      change = executeCommand(message, reply, handler);
    } catch (const std::exception &error) {
      reply.status = ClientCommandStatus::failed;
      reply.text = error.what();
      transport_.send(reply);

      return Change::none;
    }

    transport_.send(reply);

    return change;
  }

  template <ClientCommandHandler Handler>
  inline Change executeCommand(const ClientCommand &message, tbc::view<CompleteClientCommand &, tbc::lt::a> reply, Handler &handler) {
    switch (message.action) {
    case ClientAction::layout_get:
      reply.text = exportLayout();

      return Change::none;
    case ClientAction::layout_apply:
      importLayout(message.text);
      reply.text = {};

      return Change::model;
    case ClientAction::tab_next:
    case ClientAction::tab_previous:
    case ClientAction::workspace_select:
    case ClientAction::tab_create:
    case ClientAction::tab_select:
      executeNavigationCommand(message, reply);

      return Change::model;
    case ClientAction::pane_create:
    case ClientAction::pane_split:
    case ClientAction::pane_close:
    case ClientAction::pane_focus:
    case ClientAction::pane_resize:
    case ClientAction::pane_fullscreen:
    case ClientAction::pane_scroll:
    case ClientAction::pane_copy:
      executePaneCommand(message, reply);

      return Change::model;
    case ClientAction::sidebar_get:
    case ClientAction::sidebar_show:
    case ClientAction::sidebar_hide:
    case ClientAction::sidebar_resize:
      return executeSidebarCommand(message, reply);
    case ClientAction::workspace_list_collapse:
    case ClientAction::workspace_list_expand:
      setWorkspaceListCollapsed(message.action == ClientAction::workspace_list_collapse);

      return Change::configuration;
    case ClientAction::client_clipboard_copy:
      clipboard_ = message.text;
      reply.text = {};
      reply.status = ClientCommandStatus::admitted;

      return Change::clipboard;
    case ClientAction::notification_dismiss:
      if (!dismissNotification(NotificationId{message.target_id})) {
        throw EncodingError{"NotificationNotFound"};
      }

      return Change::notification;
    default:
      handler(message, reply);

      return Change::none;
    }
  }

  // A command that changes nothing is `applied`,
  // one that starts a change is `admitted`, and the target stays the one the
  // CLI sent, which the runtime matches the completion by.
  inline void executeNavigationCommand(const ClientCommand &message, CompleteClientCommand &reply) {
    switch (message.action) {
    case ClientAction::tab_next:
    case ClientAction::tab_previous: {
      if (!active_tab_) {
        throw EncodingError{"NoActiveTab"};
      }

      const auto before = *active_tab_;
      selectTabOffset(message.action == ClientAction::tab_next ? 1 : -1);
      reply.status = sameTab(before, *active_tab_) ? ClientCommandStatus::applied : ClientCommandStatus::admitted;
      break;
    }
    case ClientAction::workspace_select: {
      if (message.target_id == 0) {
        throw EncodingError{"InvalidWorkspaceId"};
      }

      const WorkspaceLocation location{WorkspaceLocation::Kind::workspace, message.target_id};
      if (std::ranges::none_of(workspaces_, [&](const auto &workspace) {
            return workspace.location.kind == WorkspaceLocation::Kind::workspace && workspace.location.id == message.target_id;
          })) {
        throw EncodingError{"WorkspaceNotFound"};
      }

      if (active_tab_ && sameWorkspace(active_tab_->workspace, location)) {
        break;
      }

      if (!selectWorkspace(location)) {
        throw EncodingError{"ClientBusy"};
      }

      reply.status = ClientCommandStatus::admitted;
      break;
    }
    case ClientAction::tab_create:
      if (createTab(message.text) != TabCreationOutcome::requested) {
        throw EncodingError{"ClientBusy"};
      }

      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::tab_select: {
      const auto tab = std::ranges::find_if(tabs_, [&](const auto &entry) {
        return entry->location.tab_id == message.target_id;
      });
      if (message.target_id == 0 || tab == tabs_.end()) {
        throw EncodingError{"TabNotFound"};
      }

      if (active_tab_ && sameTab(*active_tab_, (*tab)->location)) {
        break;
      }

      selectTab((*tab)->location);
      reply.status = ClientCommandStatus::admitted;
      break;
    }
    default:
      throw EncodingError{"Invalid navigation command"};
    }
  }

  inline void admitPaneSplit(ClientLayoutAxis axis, CompleteClientCommand &reply) {
    if (!split(axis)) {
      throw EncodingError{"PaneCreationUnavailable"};
    }

    reply.status = ClientCommandStatus::admitted;
  }

  inline void executePaneCommand(const ClientCommand &message, CompleteClientCommand &reply) {
    switch (message.action) {
    case ClientAction::pane_create:
      admitPaneSplit(ClientLayoutAxis::horizontal, reply);
      break;
    case ClientAction::pane_split:
      if (message.text != "horizontal" && message.text != "vertical") {
        throw EncodingError{"InvalidSplitAxis"};
      }

      focusCommandPane(message.target_id);
      admitPaneSplit(message.text == "horizontal" ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical, reply);
      reply.text = {};
      break;
    case ClientAction::pane_close:
      focusCommandPane(message.target_id);
      if (!closePane(message.target_id)) {
        throw EncodingError{"PaneClosureUnavailable"};
      }

      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::pane_focus:
      focusCommandPane(message.target_id);
      break;
    case ClientAction::pane_resize: {
      const auto direction = parseDirection(message.text);
      focusCommandPane(message.target_id);
      if (!resizeDirection(direction)) {
        throw EncodingError{"PaneResizeUnavailable"};
      }

      reply.text = {};
    } break;
    case ClientAction::pane_fullscreen:
      focusCommandPane(message.target_id);
      toggleFullscreen();
      reply.value = activeTab()->fullscreen;
      break;
    case ClientAction::pane_scroll:
      if (message.value < std::numeric_limits<std::int32_t>::min() || message.value > std::numeric_limits<std::int32_t>::max()) {
        throw EncodingError{"InvalidScrollDelta"};
      }

      if (!commandPane(message.target_id).attached || copy_mode_.active()) {
        throw EncodingError{"PaneViewportUnavailable"};
      }

      scroll({.pane_id = message.target_id, .rows = -message.value});
      break;
    case ClientAction::pane_copy:
      if (!commandPane(message.target_id).attached) {
        throw EncodingError{"TerminalPaneNotAttached"};
      }

      transport_.send(CopyRangeParser::parse(message.target_id, message.text));
      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      break;
    default:
      throw EncodingError{"Invalid pane command"};
    }
  }

  inline Change executeSidebarCommand(const ClientCommand &message, CompleteClientCommand &reply) {
    bool changed = false;
    if (message.action == ClientAction::sidebar_resize) {
      const auto width = SidebarColumns::clamp(host_columns_, message.value);
      changed = width != sidebar_columns_;
      sidebar_columns_ = width;
      if (changed) {
        retainLayout();
      }
    } else if (message.action != ClientAction::sidebar_get) {
      changed = configuration_.sidebar_visible != (message.action == ClientAction::sidebar_show);
      if (changed) {
        setSidebarVisible(message.action == ClientAction::sidebar_show);
      }
    }

    reply.value = sidebar_columns_;
    reply.text = configuration_.sidebar_visible ? "visible" : "hidden";

    return changed ? Change::configuration : Change::none;
  }

  inline static PaneDirection parseDirection(std::string_view text) {
    if (text == "left") {
      return PaneDirection::left;
    }

    if (text == "right") {
      return PaneDirection::right;
    }

    if (text == "up") {
      return PaneDirection::up;
    }

    if (text == "down") {
      return PaneDirection::down;
    }

    throw EncodingError{"Invalid pane direction"};
  }

  [[nodiscard]] inline const Pane<Memory> &commandPane(std::uint64_t identity) const {
    const auto *pane = findPane(identity);
    if (pane == nullptr || !active_tab_ || !sameTab(pane->location, *active_tab_)) {
      throw EncodingError{"Pane does not belong to the active tab"};
    }

    return *pane;
  }

  inline void focusCommandPane(std::uint64_t identity) {
    focusPane(commandPane(identity).id);
  }

  inline tbc::view<std::string_view, tbc::lt::a> exportLayout() {
    const auto *tab = activeTab();
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
    const std::array tabs{saved_tab};
    const ClientLayoutSnapshot snapshot{
        .restored = true,
        .sidebar_visible = configuration_.sidebar_visible,
        .sidebar_width = sidebar_columns_,
        .workspace_list_collapsed = workspace_list_collapsed_,
        .active_tab = tab->location,
        .tabs = tabs,
    };

    return LayoutToken::write(snapshot, command_response_);
  }

  inline void importLayout(std::string_view token) {
    auto *tab = activeTab();
    if (pending_count_ != 0 || (tab != nullptr && tab->loading)) {
      throw EncodingError{"Client has requests in flight"};
    }

    if (tab == nullptr) {
      throw EncodingError{"No active tab layout"};
    }

    const auto preset = LayoutToken::read(token);
    if (!sameTab(preset.location, tab->location)) {
      throw EncodingError{"Layout token belongs to another tab"};
    }

    validateLayoutMembership(preset);
    tab->layout.restore(preset.layout.nodes());
    ++view_version_.panes;
    tab->focused_pane = preset.focused_pane;
    tab->fullscreen = preset.fullscreen;
    synchronizeAttachments();
    retainLayout();
  }

  inline void validateLayoutMembership(const TabLayoutPreset &preset) const {
    std::size_t leaves = 0;
    for (const auto &node : preset.layout.nodes()) {
      if (const auto *leaf = std::get_if<ClientLayoutPane>(&node)) {
        const auto *pane = findPane(leaf->pane_id);
        if (pane == nullptr || !sameTab(pane->location, preset.location)) {
          throw EncodingError{"Layout token pane does not belong to its tab"};
        }

        ++leaves;
      }
    }

    const auto members = std::ranges::count_if(panes_, [&](const auto &pane) {
      return sameTab(pane->location, preset.location);
    });
    if (std::cmp_not_equal(leaves, members)) {
      throw EncodingError{"Layout token pane membership has changed"};
    }
  }

  inline std::size_t orderedTabs(tbc::view<std::array<Tab<Memory> *, maximum_tabs> &, tbc::lt::a> ordered) const noexcept {
    std::size_t count = 0;
    if (!active_tab_) {
      return count;
    }

    for (const auto &tab : tabs_) {
      if (sameWorkspace(tab->location.workspace, active_tab_->workspace)) {
        ordered[count++] = tab.get();
      }
    }

    std::sort(ordered.begin(), ordered.begin() + count, [](const auto *left, const auto *right) {
      return left->position != right->position ? left->position < right->position : left->location.tab_id < right->location.tab_id;
    });

    return count;
  }

  inline std::uint64_t neighboringPane(PaneDirection direction) {
    auto *tab = activeTab();
    if (tab == nullptr) {
      return 0;
    }

    return tab->layout.focusTarget(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, {.pane_id = tab->focused_pane, .direction = direction, .fullscreen = tab->fullscreen});
  }

  inline Change apply(const PaneFocusCommand &message) {
    auto outcome = PaneFocusOutcome::source_not_focused;
    const auto *source = focusedPane();
    if (source != nullptr && source->id == message.pane_id && source->generation == message.pane_generation) {
      const auto neighbor = neighboringPane(message.direction);
      outcome = neighbor == 0 ? PaneFocusOutcome::no_neighbor : PaneFocusOutcome::focused;
      if (neighbor != 0) {
        focusPane(neighbor);
      }
    }

    const auto *focused = focusedPane();
    transport_.send(CompletePaneFocus{message.requester, message.request_id, message.pane_id, message.pane_generation, outcome, focused == nullptr ? 0 : focused->id});

    return Change::model;
  }

  Configuration configuration_;
  ViewVersion view_version_;
  struct IslandEntry {
    prompt::Island island;
    std::int64_t output = 0;
    // The command block selected from the editor's normal mode, by its index among the pane's
    // blocks, and the row the live prompt started on when the selection began.
    std::optional<std::size_t> block;
    std::optional<std::uint32_t> live_prompt;
    // The first half of `[[`, `]]`, `[f`, `]f`, `gg`, `z.` or `yc`.
    char pending = 0;
    // Where jumps left from, by stable row at the view's top, oldest first, and which of them
    // Ctrl-O went back to: the list's end while it has not.
    std::vector<std::uint64_t> jumps;
    std::size_t jump = 0;
  };

  // The keys of the command blocks, ahead of the editor. From the normal mode: Ctrl-U and
  // Ctrl-D, or [[ and ]], step through the blocks, [f and ]f through the failed ones, Ctrl-O and
  // Ctrl-I back and forth through the jumps. On a selected block: j and k move the view a row,
  // gg to the top and G to the live end; zt, zz and zb put the block at the view's top, middle
  // or bottom; za, zc and zo fold its output, zM and zR every block's; / searches its output;
  // v and V select its output, Y copies it and yc its command; Esc, q, i, a, I, A and any other
  // key go back to the prompt.
  inline std::optional<prompt::Outcome> blockKey(std::uint64_t pane_id, IslandEntry &entry, const prompt::KeyPress &key) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr || configuration_.prompt.mode != PromptMode::telar) {
      return std::nullopt;
    }
    const auto &editor = entry.island.editor();
    const bool normal = editor.keymap() == prompt::Keymap::vim && editor.mode() == prompt::Mode::normal && !editor.pending();
    const auto count = pane->blocks.size();
    const bool selected = entry.block && *entry.block < count;
    if (!selected && !normal) {
      entry.pending = 0;
      return std::nullopt;
    }
    const bool plain = key.key == prompt::Key::character && !key.modifiers.control && !key.modifiers.alt;
    const auto character = plain ? key.character : 0U;
    const auto select = [&](std::optional<std::size_t> index) {
      recordJump(*pane, entry);
      selectBlock(pane_id, index);
    };
    const auto step = [&](int direction) {
      if (count == 0) {
        return;
      }
      if (!selected) {
        if (direction < 0) {
          select(count - 1);
        }
        return;
      }
      if (direction < 0) {
        select(*entry.block == 0 ? 0 : *entry.block - 1);
      } else {
        select(*entry.block + 1 < count ? std::optional<std::size_t>{*entry.block + 1} : std::nullopt);
      }
    };
    // The next failed block above or below the selected one, or from the live end.
    const auto step_failed = [&](int direction) {
      auto index = selected ? static_cast<std::ptrdiff_t>(*entry.block) : static_cast<std::ptrdiff_t>(count);
      for (index += direction; index >= 0 && std::cmp_less(index, count); index += direction) {
        if (pane->blocks[static_cast<std::size_t>(index)].state == CommandBlockState::failed) {
          select(static_cast<std::size_t>(index));
          return;
        }
      }
    };

    if (key.key == prompt::Key::character && key.modifiers.control && !key.modifiers.alt) {
      switch (key.character) {
      case 'u':
      case 'd':
        entry.pending = 0;
        step(key.character == 'u' ? -1 : 1);
        return prompt::Outcome::edited;
      case 'o':
      case 'i':
        entry.pending = 0;
        jumpBack(*pane, entry, key.character == 'o');
        return prompt::Outcome::edited;
      default:
        break;
      }
    }
    const auto pending = std::exchange(entry.pending, 0);
    if (pending == '[' || pending == ']') {
      const int direction = pending == '[' ? -1 : 1;
      if (character == static_cast<unsigned>(pending)) {
        step(direction);
      } else if (character == 'f') {
        step_failed(direction);
      }
      return prompt::Outcome::edited;
    }
    if (character == '[' || character == ']') {
      entry.pending = static_cast<char>(character);
      return prompt::Outcome::edited;
    }
    if (!selected) {
      return std::nullopt;
    }

    const auto index = *entry.block;
    const auto &block = pane->blocks[index];
    const auto rows = static_cast<std::uint64_t>(pane->screen.rows());
    const auto top = shownTop(*pane);
    const auto separator = pane->folds.display(static_cast<std::uint64_t>(block.row) + block.rows - 1);
    switch (pending) {
    case 'y':
      if (character == 'c') {
        clipboard_.assign(block.command);
        clipboard_written_ = true;
      }
      return prompt::Outcome::edited;
    case 'g':
      if (character == 'g') {
        recordJump(*pane, entry);
        scrollToShownRow(*pane, 0);
      }
      return prompt::Outcome::edited;
    case 'z':
      switch (character) {
      case 'a':
        fold(pane_id, index, !folded(pane_id, index));
        break;
      case 'c':
        fold(pane_id, index, true);
        break;
      case 'o':
        fold(pane_id, index, false);
        break;
      case 'M':
        foldAll(pane_id, true);
        break;
      case 'R':
        foldAll(pane_id, false);
        break;
      case 't':
        recordJump(*pane, entry);
        scrollToShownRow(*pane, separator);
        break;
      case 'z':
        recordJump(*pane, entry);
        scrollToShownRow(*pane, separator > rows / 2 ? separator - (rows / 2) : 0);
        break;
      case 'b': {
        recordJump(*pane, entry);
        const auto end = pane->folds.display(blockRows(*pane, index).second);
        scrollToShownRow(*pane, end > rows ? end - rows : 0);
        break;
      }
      default:
        break;
      }
      changed_pane_ = pane_id;
      block_changed_ = true;
      return prompt::Outcome::edited;
    default:
      break;
    }
    switch (character) {
    case 'j':
    case 'k':
      scrollToShownRow(*pane, character == 'j' ? top + 1 : (top == 0 ? 0 : top - 1));
      return prompt::Outcome::edited;
    case 'G':
      select(std::nullopt);
      return prompt::Outcome::edited;
    case 'g':
    case 'z':
    case 'y':
      entry.pending = static_cast<char>(character);
      return prompt::Outcome::edited;
    case '/':
      searchBlockOutput(*pane, index);
      return prompt::Outcome::edited;
    case 'v':
    case 'V':
      selectBlockOutput(*pane, index, character == 'V');
      return prompt::Outcome::edited;
    case 'Y':
      copyBlockOutput(*pane, index);
      return prompt::Outcome::edited;
    case 'q':
      selectBlock(pane_id, std::nullopt);
      return prompt::Outcome::edited;
    default:
      break;
    }
    // Back to the prompt: Esc and q stay in normal mode; i, a, I, A and any other key go on
    // to the editor, which enters insert mode or edits.
    selectBlock(pane_id, std::nullopt);
    if (key.key == prompt::Key::escape) {
      return prompt::Outcome::edited;
    }
    return std::nullopt;
  }

  // The shown row at the view's top: as its view says, or as the runtime's view puts it.
  [[nodiscard]] inline static std::uint64_t shownTop(const Pane<Memory> &pane) noexcept {
    return pane.shown_top.value_or(pane.folds.display(pane.screen.scroll().offset));
  }

  // Scrolls the pane so that shown row `display`, folds counted, is the view's top.
  inline void scrollToShownRow(const Pane<Memory> &pane, std::uint64_t display) {
    const auto row = pane.folds.row(display);
    scrollToRow(pane.id, static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max())));
    changed_pane_ = pane.id;
    block_changed_ = true;
  }

  // Remembers the view's top before a jump, dropping the jumps Ctrl-O had gone back past.
  inline void recordJump(const Pane<Memory> &pane, IslandEntry &entry) {
    constexpr std::size_t maximum_jumps = 64;
    const auto here = pane.scrollback_trimmed + pane.folds.row(shownTop(pane));
    entry.jumps.resize(std::min(entry.jump, entry.jumps.size()));
    if (entry.jumps.empty() || entry.jumps.back() != here) {
      entry.jumps.push_back(here);
    }
    if (entry.jumps.size() > maximum_jumps) {
      entry.jumps.erase(entry.jumps.begin());
    }
    entry.jump = entry.jumps.size();
  }

  // Back to where the last jump left from, or forward again; the view's top goes there.
  inline void jumpBack(const Pane<Memory> &pane, IslandEntry &entry, bool back) {
    if (back) {
      if (entry.jump == 0 || entry.jumps.empty()) {
        return;
      }
      if (entry.jump == entry.jumps.size()) {
        // The first step back remembers where it left, for Ctrl-I to return to.
        const auto here = pane.scrollback_trimmed + pane.folds.row(shownTop(pane));
        if (entry.jumps.back() != here) {
          entry.jumps.push_back(here);
        }
        entry.jump = entry.jumps.size() - 1;
      }
      --entry.jump;
    } else {
      if (entry.jump + 1 >= entry.jumps.size()) {
        return;
      }
      ++entry.jump;
    }
    const auto stable = entry.jumps[entry.jump];
    const auto row = stable > pane.scrollback_trimmed ? stable - pane.scrollback_trimmed : 0;
    scrollToRow(pane.id, static_cast<std::uint32_t>(std::min<std::uint64_t>(row, std::numeric_limits<std::uint32_t>::max())));
    changed_pane_ = pane.id;
    block_changed_ = true;
  }

  // Copy mode on a block's output, at its first row, with the scrollback search asked for and
  // confined to that output.
  inline void searchBlockOutput(Pane<Memory> &pane, std::size_t index) {
    const auto [first, last] = blockOutput(pane, index);
    const auto grid = copyGrid(pane.screen);
    if (folded(pane.id, index)) {
      fold(pane.id, index, false);
    }
    if (copy_mode_.enterAt(pane.id, grid, CopyPoint{.x = 0, .y = first}, std::nullopt, false)) {
      copy_search_request_ = 0;
      copy_search_rows_ = CopySearchRows{.block = index, .first = first, .last = last};
      copy_search_origin_ = CopyPoint{.x = 0, .y = first};
      copy_search_scoped_ = readsRows();
      search_requested_ = true;
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  // The rows of a block's output: from under its command to above the next block's prompt, or
  // the live prompt's for the last one.
  [[nodiscard]] inline std::pair<std::uint32_t, std::uint32_t> blockOutput(const Pane<Memory> &pane, std::size_t index) const {
    const auto &block = pane.blocks[index];
    const auto first = block.row + block.rows;
    std::uint32_t end = pane.screen.scroll().total_rows;
    if (index + 1 < pane.blocks.size()) {
      end = pane.blocks[index + 1].row;
    } else if (const auto found = islands_.find(pane.id); found != islands_.end() && found->second.live_prompt) {
      end = *found->second.live_prompt;
    }
    return {first, std::max(first, end == 0 ? 0 : end - 1)};
  }

  // Copy mode on a block's output: from its first character, or every line of it selected.
  inline void selectBlockOutput(const Pane<Memory> &pane, std::size_t index, bool lines) {
    const auto [first, last] = blockOutput(pane, index);
    const auto grid = copyGrid(pane.screen);
    const auto columns = static_cast<std::uint16_t>(grid.columns == 0 ? 0 : grid.columns - 1);
    const CopyPoint start{.x = 0, .y = first};
    if (copy_mode_.enterAt(pane.id, grid, lines ? CopyPoint{.x = columns, .y = last} : start, start, lines)) {
      copy_search_request_ = 0;
      changed_pane_ = pane.id;
      block_changed_ = true;
    }
  }

  // A block's whole output to the clipboard, as the runtime reads it.
  inline void copyBlockOutput(const Pane<Memory> &pane, std::size_t index) {
    const auto [first, last] = blockOutput(pane, index);
    const auto columns = pane.screen.columns();
    transport_.send(CopySelection{.pane_id = pane.id, .start_x = 0, .start_y = first, .end_x = static_cast<std::uint16_t>(columns == 0 ? 0 : columns - 1), .end_y = last, .linewise = true});
  }

  // The row the shell's live prompt starts on, from the top of the scrollback, while the pane
  // shows its live end.
  [[nodiscard]] inline static std::optional<std::uint32_t> livePromptRow(const Pane<Memory> &pane) {
    const auto &screen = pane.screen;
    const auto &scroll = screen.scroll();
    if (static_cast<std::uint64_t>(scroll.offset) + screen.rows() < scroll.total_rows) {
      return std::nullopt;
    }
    const auto cursor = static_cast<std::size_t>(screen.cursor().y);
    for (auto row = cursor + 1; row-- > 0 && cursor - row < 8;) {
      if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
        return scroll.offset + static_cast<std::uint32_t>(row);
      }
    }
    return std::nullopt;
  }

  inline IslandEntry &islandEntry(std::uint64_t pane_id) {
    const auto keymap = configuration_.prompt.keymap == PromptKeymap::vim ? prompt::Keymap::vim : prompt::Keymap::emacs;
    auto [found, inserted] = islands_.try_emplace(pane_id, IslandEntry{prompt::Island{keymap}});
    found->second.island.setKeymap(keymap);
    if (inserted && prompt_history_.empty()) {
      requestPromptHistory();
    }
    return found->second;
  }

  // The commands people typed, most recent first and each once, for the editor's suggestions.
  inline void requestPromptHistory() {
    if (!ready_ || !configuration_.prompt.ghost || prompt_history_request_ != 0) {
      return;
    }
    const QueryHistory query{.request_id = nextRequest(), .author = HistoryAuthorFilter::human, .distinct = true, .limit = 1000};
    try {
      transport_.send(query);
      prompt_history_request_ = query.request_id;
    } catch (const std::length_error &) {
    }
  }

  static_assert(runtime::config::prompt_action_names.size() == static_cast<std::size_t>(prompt::Action::insert_mode) + 1);

  // The action the user bound to this key in the editor's current mode, if any.
  inline std::optional<prompt::Action> boundAction(const prompt::KeyPress &key, const prompt::Editor &editor) const {
    using Chord = runtime::config::KeyChord;
    const bool normal = editor.keymap() == prompt::Keymap::vim && editor.mode() != prompt::Mode::insert;
    const auto named = [&]() -> std::optional<Chord::Key> {
      switch (key.key) {
      case prompt::Key::character:
        return Chord::Key::character;
      case prompt::Key::enter:
        return Chord::Key::enter;
      case prompt::Key::backspace:
        return Chord::Key::backspace;
      case prompt::Key::delete_forward:
        return Chord::Key::erase;
      case prompt::Key::left:
        return Chord::Key::left;
      case prompt::Key::right:
        return Chord::Key::right;
      case prompt::Key::up:
        return Chord::Key::up;
      case prompt::Key::down:
        return Chord::Key::down;
      case prompt::Key::home:
        return Chord::Key::home;
      case prompt::Key::end:
        return Chord::Key::end;
      case prompt::Key::tab:
        return Chord::Key::tab;
      case prompt::Key::backtab:
        return Chord::Key::back_tab;
      case prompt::Key::escape:
        return Chord::Key::escape;
      }
      return std::nullopt;
    }();
    if (!named) {
      return std::nullopt;
    }
    unsigned modifiers = (key.modifiers.control ? static_cast<unsigned>(Chord::Modifier::control) : 0U) | (key.modifiers.alt ? static_cast<unsigned>(Chord::Modifier::alt) : 0U);
    // A shifted character is its own character; Shift counts only with named keys.
    if (*named != Chord::Key::character && key.modifiers.shift) {
      modifiers |= static_cast<unsigned>(Chord::Modifier::shift);
    }
    const auto character = *named == Chord::Key::character ? KeyCharacter::pack(key.character) : 0U;
    for (const auto &binding : configuration_.prompt.bindings) {
      if (binding.normal == normal && binding.key == static_cast<std::uint8_t>(*named) && binding.modifiers == modifiers && binding.character == character) {
        return static_cast<prompt::Action>(binding.action);
      }
    }
    return std::nullopt;
  }

  // Sends what the editor decided: a command to run, a line for the running program, or raw
  // bytes the shell reads as keys. Commands are validated like a pasted history entry.
  inline void deliverPrompt(std::uint64_t pane_id, prompt::Outcome outcome, const prompt::Island &island) {
    const auto *pane = findPane(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited) {
      return;
    }
    const auto text = island.delivery();
    switch (outcome) {
    case prompt::Outcome::run:
      if (text.empty()) {
        input(pane_id, "\r");
        break;
      }
      HistoryText::validate(text, pane->screen.modes().bracketed_paste);
      runCommand(pane_id, text);
      // Every pane's suggestions know the command at once, without asking the history again.
      std::erase(prompt_history_, text);
      prompt_history_.insert(prompt_history_.begin(), std::string{text});
      break;
    case prompt::Outcome::answer: {
      HistoryText::validate(text.empty() ? std::string_view{" "} : text, false);
      std::string line{text};
      line.push_back('\r');
      input(pane_id, line);
      break;
    }
    case prompt::Outcome::bytes:
      input(pane_id, text);
      break;
    default:
      break;
    }
  }

  // Tab: the spec's literal choices at once, and the runtime's files when the spec, or a
  // command without one, expects a path there.
  inline void beginCompletion(std::uint64_t pane_id, prompt::Island &island, shell::Syntax syntax) {
    const auto *pane = findPane(pane_id);
    const auto &text = island.editor().text();
    auto context = prompt::completionContext(text.view(), text.cursor(), syntax);
    if (pane == nullptr || !context) {
      return;
    }

    // A command's spec comes from the runtime, for the commands this pane's shell runs; while
    // it is on its way, Tab waits for it and completes once it arrives.
    const ebnf::command_spec *spec = nullptr;
    if (!context->command_position && !pane->shell.remote && ready_) {
      switch (specState(pane_id, context->command)) {
      case SpecState::available: {
        // An alias completes as the words it stands for: `gst -` as `git status -`.
        const auto &aliases = command_checks_[pane_id].aliases;
        if (const auto alias = aliases.find(context->command); alias != aliases.end()) {
          std::vector<std::string> words;
          for (auto rest = std::string_view{alias->second}; !rest.empty();) {
            const auto end = rest.find(' ');
            if (end != 0) {
              words.emplace_back(rest.substr(0, end));
            }
            rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
          }
          if (!words.empty()) {
            context->command = words.front().substr(words.front().rfind('/') + 1);
            context->words.insert(context->words.begin(), words.begin() + 1, words.end());
            spec = prompt_specs_.find(words.front());
          }
        } else {
          spec = prompt_specs_.find(context->command);
        }
        break;
      }
      case SpecState::pending:
        spec_completions_.insert_or_assign(pane_id, std::string{text.view()});
        return;
      case SpecState::unavailable:
        break;
      }
    }
    auto completion = prompt::complete(*context, spec, prompt_specs_.scratch(), island.recent());
    const auto wants = [&](std::string_view provider) { return std::ranges::find(completion.providers, provider) != completion.providers.end(); };
    auto partial = std::string_view{context->partial};
    if (partial.starts_with(completion.provider_prefix)) {
      partial.remove_prefix(completion.provider_prefix.size());
    }
    std::vector<std::uint64_t> requests;
    // A remote shell's files, branches and commands are on its host: only the spec's own
    // choices apply there.
    const bool local = !pane->shell.remote;
    if (ready_ && local && (wants("file") || wants("directory"))) {
      const auto slash = partial.rfind('/');
      const auto directory = slash == std::string_view::npos ? std::string_view{} : partial.substr(0, slash + 1);
      std::string root{directory.starts_with('/') ? std::string_view{} : std::string_view{pane->cwd}};
      if (!directory.starts_with('/') && !root.ends_with('/')) {
        root.push_back('/');
      }
      root.append(directory);
      while (root.size() > 1 && root.ends_with('/')) {
        root.pop_back();
      }
      const auto query = slash == std::string_view::npos ? partial : partial.substr(slash + 1);
      if (root.starts_with('/') && query.size() <= 64) {
        const FindPaths find{.request_id = nextRequest(), .root = root, .query = query, .kind = wants("file") ? PathKindFilter::any : PathKindFilter::directories, .limit = 50};
        try {
          transport_.send(find);
          requests.push_back(find.request_id);
          path_completions_.emplace(find.request_id, PathCompletion{pane_id, completion.provider_prefix + std::string{directory}, std::string{query}});
        } catch (const std::length_error &) {
        }
      }
    }

    // Commands on the shell's PATH, branches, SSH hosts and make targets come from the runtime.
    // A spec's @ref is a branch name as far as the editor completes it.
    static constexpr std::array<std::pair<std::string_view, CompletionProvider>, 10> providers{{{"command", CompletionProvider::command}, {"branch", CompletionProvider::branch}, {"ssh_host", CompletionProvider::ssh_host}, {"make_target", CompletionProvider::make_target}, {"remote", CompletionProvider::remote}, {"stash", CompletionProvider::stash}, {"process", CompletionProvider::process}, {"just_recipe", CompletionProvider::just_recipe}, {"package_script", CompletionProvider::package_script}, {"compose_service", CompletionProvider::compose_service}}};
    for (const auto &[name, provider] : providers) {
      const bool asked = context->command_position ? provider == CompletionProvider::command : wants(name) || (provider == CompletionProvider::branch && wants("ref"));
      if (!ready_ || !local || !asked || partial.size() > 256) {
        continue;
      }
      const CompleteWords request{.request_id = nextRequest(), .pane_id = pane_id, .provider = provider, .prefix = partial};
      try {
        transport_.send(request);
        requests.push_back(request.request_id);
        path_completions_.emplace(request.request_id, PathCompletion{pane_id, completion.provider_prefix, std::string{partial}});
      } catch (const std::length_error &) {
      }
    }
    // The heading names where the choices come from.
    const auto label = [&]() -> std::string {
      if (context->command_position) {
        return "commands";
      }
      static constexpr std::array<std::pair<std::string_view, std::string_view>, 12> sources{{{"branch", "branches · git"}, {"ref", "branches · git"}, {"remote", "remotes · git"}, {"stash", "stashes · git"}, {"ssh_host", "hosts · ssh"}, {"make_target", "targets · make"}, {"just_recipe", "recipes · just"}, {"package_script", "scripts · package.json"}, {"compose_service", "services · compose"}, {"process", "processes"}, {"file", "files"}, {"directory", "directories"}}};
      for (const auto &[provider, name] : sources) {
        if (wants(provider)) {
          return std::string{name};
        }
      }
      return context->command;
    };
    island.offer(std::move(completion.choices), context->replace_begin, context->replace_end, std::move(requests), syntax.dialect, label());
  }

  struct PathCompletion {
    std::uint64_t pane_id;
    std::string base;
    std::string query;
  };

  enum class SpecState : std::uint8_t {
    pending,
    available,
    unavailable,
  };

  struct CommandRequest {
    std::uint64_t pane_id;
    std::string word;
  };

  struct StringHash {
    using is_transparent = void;

    inline std::size_t operator()(std::string_view text) const noexcept {
      return std::hash<std::string_view>{}(text);
    }
  };

  struct CommandChecks {
    std::uint32_t commands = 0;
    std::string directory;
    std::unordered_map<std::string, CommandPresence, StringHash, std::equal_to<>> words;
    // Commands seen running, kept across commands.
    std::unordered_set<std::string, StringHash, std::equal_to<>> learned;
    // Whether the runtime has a spec for each command asked about, and what each alias
    // among them stands for.
    std::unordered_map<std::string, SpecState, StringHash, std::equal_to<>> specs;
    std::unordered_map<std::string, std::string, StringHash, std::equal_to<>> aliases;
    // The command each alias last stood for, kept across commands for the digest it asks with.
    std::unordered_map<std::string, std::string, StringHash, std::equal_to<>> alias_targets;
  };

  // What the pane learned of its shell's commands, forgotten after each command and change of
  // directory: either may change which commands run.
  inline CommandChecks &commandChecks(const Pane<Memory> &pane) {
    auto &checks = command_checks_[pane.id];
    if (checks.commands != pane.shell.commands || checks.directory != std::string_view{pane.cwd} || checks.words.size() > 512) {
      checks.commands = pane.shell.commands;
      checks.directory.assign(pane.cwd);
      checks.words.clear();
      checks.specs.clear();
      checks.aliases.clear();
    }
    return checks;
  }

  // The first command `line` runs, as the editor colours it.
  inline void learnCommand(std::uint64_t pane_id, std::string_view line, shell::Dialect dialect) {
    std::vector<prompt::Style> styles(line.size());
    prompt::classify(line, styles, shell::Syntax{.dialect = dialect});
    const auto start = std::ranges::find_if(styles, [](prompt::Style style) { return style == prompt::Style::command || style == prompt::Style::pending; });
    if (start == styles.end()) {
      return;
    }
    const auto first = static_cast<std::size_t>(start - styles.begin());
    auto end = first;
    while (end < styles.size() && styles[end] == styles[first]) {
      ++end;
    }
    auto &checks = command_checks_[pane_id];
    if (checks.learned.size() >= 256) {
      checks.learned.clear();
    }
    const auto word = line.substr(first, end - first);
    checks.learned.emplace(word);
    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      known->second = CommandPresence::found;
    }
  }

  // Whether the runtime has a spec for `command` in this pane, asking it the first time: once
  // per command until the shell's next command, with the digest of the spec already held.
  inline SpecState specState(std::uint64_t pane_id, std::string_view command) {
    if (command.empty() || command.size() > 64) {
      return SpecState::unavailable;
    }
    const auto *pane = findPane(pane_id);
    if (pane == nullptr) {
      return SpecState::unavailable;
    }
    auto &checks = commandChecks(*pane);
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      return known->second;
    }
    // An alias's spec is its command's: the digest of the one held for what it last stood for.
    const auto target = checks.alias_targets.find(command);
    const RequestCommandSpec request{.request_id = nextRequest(), .pane_id = pane_id, .command = command, .known_digest = prompt_specs_.digest(target == checks.alias_targets.end() ? command : std::string_view{target->second})};
    try {
      transport_.send(request);
    } catch (const std::exception &) {
      checks.specs.emplace(std::string{command}, SpecState::unavailable);
      return SpecState::unavailable;
    }
    checks.specs.emplace(std::string{command}, SpecState::pending);
    spec_requests_.emplace(request.request_id, CommandRequest{pane_id, std::string{command}});
    return SpecState::pending;
  }

  inline Change settleCommand(typename std::unordered_map<std::uint64_t, CommandRequest>::iterator request, CommandPresence presence) {
    const auto [pane_id, word] = std::move(request->second);
    command_requests_.erase(request);
    // A command the shell runs may have a spec: asked now, it is there by the first Tab.
    if (presence == CommandPresence::found && word.find('/') == std::string::npos) {
      static_cast<void>(specState(pane_id, word));
    }
    const auto checks = command_checks_.find(pane_id);
    if (checks == command_checks_.end()) {
      return Change::none;
    }
    const auto known = checks->second.words.find(word);
    if (known == checks->second.words.end() || known->second != CommandPresence::pending) {
      return Change::none;
    }
    known->second = presence;
    changed_pane_ = pane_id;
    return Change::terminal;
  }

  prompt::Specs prompt_specs_;
  std::vector<std::string> prompt_history_;
  std::uint64_t prompt_history_request_ = 0;
  std::unordered_map<std::uint64_t, PathCompletion> path_completions_;
  std::unordered_map<std::uint64_t, CommandRequest> command_requests_;
  std::unordered_map<std::uint64_t, CommandChecks> command_checks_;
  std::unordered_map<std::uint64_t, CommandRequest> spec_requests_;
  // Tab pressed while a pane waited for a spec: the line it completes, by pane.
  std::unordered_map<std::uint64_t, std::string> spec_completions_;
  bool chrome_changed_ = false;
  bool clipboard_written_ = false;
  bool block_changed_ = false;
  std::uint64_t prompt_written_ = 0;
  std::unordered_map<std::uint64_t, IslandEntry> islands_;
  CopyMode copy_mode_;
  EditorOpening editor_opening_;
  std::uint64_t copy_search_request_ = 0;
  // The output a search begun from a command reads, and whether it reads only that.
  struct CopySearchRows {
    std::size_t block = 0;
    std::uint32_t first = 0;
    std::uint32_t last = 0;
  };
  std::optional<CopySearchRows> copy_search_rows_;
  // Where the search being typed began, what it looks for, and whether its answer kept fewer
  // matches than it found.
  std::optional<CopyPoint> copy_search_origin_;
  std::string copy_search_query_;
  bool copy_search_truncated_ = false;
  bool copy_search_scoped_ = false;
  bool search_requested_ = false;
  HostMetrics metrics_;
  ProxyStatus proxy_{};
  tbc::view<Memory &, tbc::lt::a> memory_;
  tbc::view<Transport &, tbc::lt::a> transport_;
  [[no_unique_address]] Effects effects_;
  SoundPlayback sound_playback_;
  GraphicsBudget graphics_budget_;
  GraphicsPauses graphics_pauses_;
  LimitReports limit_reports_;
  static constexpr std::uint64_t limit_notice_duration_ns = 8'000'000'000;
  tbc::view<Vector<Owned<Pane<Memory>, Memory>, Memory>, tbc::lt::a> panes_;
  tbc::view<Vector<Owned<Tab<Memory>, Memory>, Memory>, tbc::lt::a> tabs_;
  tbc::view<WorkspaceReplica<Memory>, tbc::lt::a> workspaces_;
  tbc::view<AgentReplica<Memory>, tbc::lt::a> agents_;
  tbc::view<PaneListReplica<Memory>, tbc::lt::a> pane_list_;
  AgentAcknowledgement agent_acknowledgement_;
  NotificationCenter notifications_;
  std::uint64_t notification_revision_ = 0;
  tbc::view<HistoryBrowser<Memory>, tbc::lt::a> history_;
  tbc::view<PeekScreen<Memory>, tbc::lt::a> peek_;
  PathPickerPage path_picker_;
  // The relative word before the island's caret when the path search opened over it.
  struct PathSeed {
    std::uint64_t pane_id = 0;
    std::size_t begin = 0;
    runtime::FixedText<PathPickerLimits::query_bytes> text;
  };
  PathSeed path_seed_;
  SuggestionState suggestion_;
  tbc::view<Vector<Byte, Memory>, tbc::lt::a> decode_;
  tbc::view<String<Memory>, tbc::lt::a> clipboard_;
  tbc::view<String<Memory>, tbc::lt::a> notice_;
  tbc::view<String<Memory>, tbc::lt::a> error_;
  tbc::view<String<Memory>, tbc::lt::a> command_response_;
  tbc::view<String<Memory>, tbc::lt::a> launch_cwd_;
  tbc::view<Vector<String<Memory>, Memory>, tbc::lt::a> argument_storage_;
  // The launch arguments view the strings stored beside them; the protocol allows at most 64.
  tbc::view<std::array<std::string_view, maximum_launch_arguments>, tbc::lt::self> launch_arguments_{};
  std::size_t launch_argument_count_ = 0;
  std::array<Pending, maximum_pending> pending_;
  std::size_t pending_count_ = 0;
  std::optional<TabLocation> active_tab_;
  NavigationHistory navigation_history_;
  SavedLayouts saved_layouts_;
  std::optional<NavigationHistory::Bookmark> pending_layout_restore_;
  std::optional<TabLocation> deferred_tab_;
  std::optional<MachineBookmark> left_machine_;
  std::uint64_t request_id_ = 0;
  std::uint64_t attachment_generation_ = 0;
  std::uint64_t changed_pane_ = 0;
  WorkbenchGeometry workbench_geometry_;
  std::optional<PaneBottomReservation> attachment_reservation_;
  bool attachment_resize_pending_ = false;
  bool ready_ = false;
  bool reads_rows_ = false;
  bool fold_changed_ = false;
  bool presented_ = true;
  bool leave_pending_ = false;
  bool initial_open_pending_ = false;
  bool restore_layout_ = true;
  bool workspace_list_collapsed_ = false;
  std::uint16_t display_fps_ = Configuration::default_fps;
  std::uint16_t sidebar_columns_ = default_sidebar_columns;
  std::uint16_t host_columns_ = default_terminal_size.cols;
};

}
}
