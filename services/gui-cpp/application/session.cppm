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

  inline void connected(std::uint64_t identity) {
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
    case ServerTag::pane_clipboard:
      return dispatch.template operator()<PaneClipboard>();
    case ServerTag::pane_matches:
      return dispatch.template operator()<PaneMatches>();
    case ServerTag::pane_text:
      return dispatch.template operator()<PaneText>();
    case ServerTag::agent_snapshot:
      return dispatch.template operator()<AgentSnapshot>();
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

  // Without a directory the workspace starts where the focused pane is, as
  // in Zig.
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

    if (source == PaneInputSource::keyboard || source == PaneInputSource::key_release) {
      static_cast<void>(copy_mode_.clearPointer());
      if (source != PaneInputSource::key_release) {
        const auto bottom = copyGrid(pane->screen).maximumOffset();
        if (pane->screen.scroll().offset != bottom) {
          ++view_version_.viewport;
          pane->screen.setViewport(bottom);
          transport_.send(SetPaneViewport{.pane_id = pane_id, .offset = bottom});
        }
      }
    }

    auto pending_bytes = byteView(bytes);
    while (!pending_bytes.empty()) {
      const auto count = std::min(pending_bytes.size(), input_chunk_size);
      transport_.send(PaneInput{.pane_id = pane_id, .bytes = pending_bytes.first(count)});
      if constexpr (PaneInputObserver<Effects>) {
        if (source != PaneInputSource::terminal_report && pending_bytes.size() == bytes.size()) {
          effects_.notePaneInput({.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = pane->attached, .attachment_generation = pane->attachment_generation, .graphics_revision = pane->graphics.revision()}, Clock::nowNanoseconds());
        }
      }

      pending_bytes = pending_bytes.subspan(count);
    }
  }

  inline void paste(std::uint64_t pane_id, std::string_view bytes) {
    if (copy_mode_.active()) {
      return;
    }

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
    requestPaths({});

    return true;
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

    const auto paste = PathInsertion::prepare(path_picker_, {.selection = selection, .absolute = absolute, .bracketed = pane->screen.modes().bracketed_paste});
    if (!paste) {
      return false;
    }

    try {
      input(pane->id, paste->view());
    } catch (const std::length_error &) {
      path_picker_.setError("Input is busy; retry");

      return false;
    }

    path_picker_.close();

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
      const auto fallback = agent != agents_.end() && agent->location.workspace.kind == WorkspaceLocation::Kind::workspace ? std::optional{agent->location.workspace.id} : std::nullopt;
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

    transport_.send(SetPaneViewport{.pane_id = delta.pane_id, .offset = requested});
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

    return plan->effect;
  }

  inline void leaveCopyMode() {
    if (auto *pane = copyPane()) {
      applyCopyPlan(copy_mode_.leave(copyGrid(pane->screen)), *pane);
    } else {
      copy_mode_.reset();
    }

    copy_search_request_ = 0;
  }

  inline void searchCopy(std::string_view needle) {
    const auto *pane = copyPane();
    if (pane == nullptr || !copy_mode_.active()) {
      throw EncodingError{"No copy mode owns this search"};
    }

    const SearchPane request{.request_id = nextRequest(), .pane_id = pane->id, .needle = needle};
    transport_.send(request);
    copy_search_request_ = request.request_id;
  }

  inline void queryHistory(std::string_view query) {
    queryHistory(query, {.author = configuration_.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  inline void queryHistory(std::string_view query, HistoryFilters filters) {
    const auto parsed = HistorySearch::parse(query, filters.failed_only);
    QueryHistory request{.request_id = nextRequest(), .query = parsed.query, .failed_only = parsed.failed_only, .author = filters.author, .match = configuration_.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy};
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
    configuration_ = configuration;
    sound_playback_.configure(configuration.sound);
    ++view_version_.configuration;
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

    const auto plan = copy_mode_.search(message.matches, copyGrid(pane->screen));
    if (plan) {
      applyCopyPlan(*plan, *pane);
    }

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

      pane->snapshot_requested = false;
      changed_pane_ = pane->id;

      return Change::terminal;
    }

    return Change::none;
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
      tab.observeForegrounds(descriptor.foregrounds);
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
      if (tab->foreground_pane == message.pane_id) {
        tab->observeForeground(message);
      }
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

  Change apply(const HistoryResults &message) {
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

  Change apply(const PathResults &message) {
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
    // The reply starts as the command, text included, as Zig's: the actions
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

  // As Zig's `cli_control.zig`: a command that changes nothing is `applied`,
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
  CopyMode copy_mode_;
  EditorOpening editor_opening_;
  std::uint64_t copy_search_request_ = 0;
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
  AgentAcknowledgement agent_acknowledgement_;
  NotificationCenter notifications_;
  std::uint64_t notification_revision_ = 0;
  tbc::view<HistoryBrowser<Memory>, tbc::lt::a> history_;
  tbc::view<PeekScreen<Memory>, tbc::lt::a> peek_;
  PathPickerPage path_picker_;
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
