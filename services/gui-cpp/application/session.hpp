#pragma once

#include "agent_acknowledgement.hpp"
#include "agent_alerts.hpp"
#include "agent_replica.hpp"
#include "agent_status_change.hpp"
#include "client_view_state.hpp"
#include "command_handler.hpp"
#include "config/command_tab_view.hpp"
#include "core/configuration.hpp"
#include "core/monotonic_clock.hpp"
#include "core/terminal_size.hpp"
#include "core/view_version.hpp"
#include "graphics/limit.hpp"
#include "graphics/pauses.hpp"
#include "graphics/resync_required.hpp"
#include "history/browser.hpp"
#include "history/entry.hpp"
#include "history/search.hpp"
#include "host_effects.hpp"
#include "host_metrics.hpp"
#include "input/copy_pointer.hpp"
#include "input/history_text.hpp"
#include "input/key_encoder.hpp"
#include "input/mouse_encoder.hpp"
#include "input/paste_encoding.hpp"
#include "input/terminal_key.hpp"
#include "input/wheel_accumulator.hpp"
#include "layout_token.hpp"
#include "limit_reports.hpp"
#include "links/editor_launch.hpp"
#include "links/editor_opening.hpp"
#include "links/file_path.hpp"
#include "links/path_expansion.hpp"
#include "notification_center.hpp"
#include "notification_item.hpp"
#include "paths/insertion.hpp"
#include "paths/limits.hpp"
#include "paths/page.hpp"
#include "peek/command.hpp"
#include "peek/limits.hpp"
#include "peek/screen.hpp"
#include "peek/target.hpp"
#include "platform/awake_clock.hpp"
#include "platform/observation_time.hpp"
#include "presentation/agent_card_labels.hpp"
#include "presentation/agent_order.hpp"
#include "presentation/frame_pacer.hpp"
#include "presentation/sidebar_columns.hpp"
#include "presentation/window_title.hpp"
#include "records.hpp"
#include "sound_playback.hpp"
#include "suggestions/limits.hpp"
#include "suggestions/state.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "terminal/copy_grid.hpp"
#include "terminal/copy_mode.hpp"
#include "terminal/copy_range.hpp"
#include "text/utf8.hpp"
#include "workbench_geometry.hpp"
#include "workspace_replica.hpp"
#include <array>
#include <concepts>
#include <limits>
#include <string_view>
#include <utility>

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

  Session(Memory &memory, Transport &transport, Effects effects = {})
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
        argument_storage_(AllocatorRef<String<Memory>, Memory>{memory}),
        launch_arguments_(AllocatorRef<std::string_view, Memory>{memory}) {
    decode_.resize(decode_capacity);
  }

  void setLaunch(const Launch &launch) {
    BodySchema<Launch>::validate(launch);
    launch_cwd_ = launch.cwd;
    argument_storage_.clear();
    launch_arguments_.clear();
    argument_storage_.reserve(launch.arguments.size());
    launch_arguments_.reserve(launch.arguments.size());
    for (const auto argument : launch.arguments) {
      argument_storage_.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
    }

    for (const auto &argument : argument_storage_) {
      launch_arguments_.push_back(argument);
    }
  }

  void setLaunchDirectory(std::string_view directory) {
    auto launch = defaultLaunch();
    launch.cwd = directory;
    BodySchema<Launch>::validate(launch);
    launch_cwd_ = directory;
  }

  void setLaunchArguments(std::span<const std::string_view> arguments) {
    auto launch = defaultLaunch();
    launch.arguments = arguments;
    setLaunch(launch);
  }

  void setRestoreLayout(bool enabled) noexcept {
    restore_layout_ = enabled;
  }

  void connected(std::uint64_t identity) {
    ready_ = true;
    transport_.send(RequestRuntimeState{.client_identity = identity, .interactive = true});
    transport_.send(ConfigureGraphics{false});
    configureCadence();
  }

  [[nodiscard]] bool requestsPending() const noexcept {
    return pending_count_ != 0;
  }

  [[nodiscard]] bool presented() const noexcept {
    return presented_;
  }

  void setPresented(bool presented) {
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

  bool settlePresentation() {
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

    releaseMachinePresentation();
    leave_pending_ = false;

    return true;
  }

  void disconnected() noexcept {
    ++view_version_.host;
    ready_ = false;
    graphics_pauses_.reset();
    agents_.resetSource();
    workspaces_.resetSource();
    metrics_ = {};
    proxy_ = {};
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

  Change consume(std::span<const Byte> payload) {
    UnsupportedClientCommand handler;

    return consume(payload, handler);
  }

  template <ClientCommandHandler Handler>
  Change consume(std::span<const Byte> payload, Handler &handler) {
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

  void selectTab(TabLocation location) {
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

  void selectWorkspace(WorkspaceLocation location) {
    sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = location});
    const auto found = std::find_if(tabs_.begin(), tabs_.end(), [&](const auto &tab) {
      return sameWorkspace(tab->location.workspace, location) && tab->workspace_active;
    });
    if (found != tabs_.end()) {
      selectTab((*found)->location);
    } else {
      requested_workspace_ = location;
    }
  }

  void selectWorkspaceIndex(std::size_t index) {
    std::size_t position = 0;
    for (const auto &workspace : workspaces_) {
      if (workspace.location.kind != WorkspaceLocation::Kind::workspace) {
        continue;
      }

      if (position++ == index) {
        selectWorkspace(workspace.location);
        return;
      }
    }
  }

  void focusPane(std::uint64_t pane_id) {
    auto *pane = findPane(pane_id);
    if (pane == nullptr) {
      const auto agent = std::find_if(agents_.begin(), agents_.end(), [&](const auto &entry) {
        return entry.pane_id == pane_id;
      });
      if (agent == agents_.end()) {
        return;
      }

      pane = &ensurePane(pane_id, agent->location);
      pane->generation = agent->pane_generation;
    }

    auto &tab = ensureTab(pane->location);
    setPaneFocus(tab, pane_id);
    selectTab(pane->location);
    synchronizeAttachments();
    retainLayout();
  }

  bool openWorktree(std::uint64_t identity) {
    const auto *row = workspaces_.worktree(identity);
    if (!ready_ || row == nullptr || !row->workspace) {
      return false;
    }

    selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = *row->workspace});

    return true;
  }

  bool leaveWorktree() {
    if (!ready_ || !active_tab_ || active_tab_->workspace.kind != WorkspaceLocation::Kind::workspace) {
      return false;
    }

    const auto *row = workspaces_.worktreeOfWorkspace(active_tab_->workspace.id);
    if (row == nullptr) {
      return false;
    }

    selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = row->source});

    return true;
  }

  std::size_t forgetGoneWorktrees() {
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

  TabCreationOutcome createTab(std::string_view label = {}) {
    return requestTabCreation(label, {});
  }

  TabCreationOutcome createCommandTab(const runtime::config::CommandTabView &command) {
    if (command.count == 0 || command.count > command.arguments.size()) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    return requestTabCreation(command.label(), command.argv());
  }

  void createWorkspace(WorkspaceDraft draft) {
    auto launch = defaultLaunch();
    if (!draft.path.empty()) {
      launch.cwd = draft.path;
    }

    sendOpeningRequest(RequestKind::create_workspace, CreateWorkspace{.size = launchSize(), .name = draft.name, .launch = launch});
  }

  template <PathEnvironment Environment>
  void openFile(const FilePath &path, std::string_view executable, const Environment &environment, std::optional<std::uint64_t> source_id = {}) {
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

  void setWorkbenchGeometry(WorkbenchGeometry geometry) noexcept {
    if (workbench_geometry_ != geometry) {
      workbench_geometry_ = geometry;
      ++view_version_.viewport;
    }
  }

  [[nodiscard]] const WorkbenchGeometry &workbenchGeometry() const noexcept {
    return workbench_geometry_;
  }

  bool split(ClientLayoutAxis axis) {
    const auto *tab = activeTab();
    if (tab == nullptr) {
      return false;
    }

    return requestPaneSplit(tab->focused_pane, axis, defaultLaunch());
  }

  bool closePane(std::uint64_t pane_id) {
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

  void closeTab(TabLocation location) {
    if (!hasTabOperation()) {
      sendTabOperation(RequestKind::close_tab, CloseTab{.location = location});
    }
  }

  void renameTab(std::string_view label) {
    if (const auto location = active_tab_; location && !hasTabOperation()) {
      sendTabOperation(RequestKind::rename_tab, RenameTab{.location = *location, .label = label});
    }
  }

  void selectTabIndex(std::size_t index) {
    std::array<Tab<Memory> *, maximum_tabs> ordered{};
    const auto count = orderedTabs(ordered);
    if (index < count) {
      selectTab(ordered[index]->location);
    }
  }

  void selectTabOffset(std::int32_t offset) {
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

  void moveTab(TabMoveDirection direction, std::optional<std::uint64_t> relative_to = {}) {
    if (const auto location = active_tab_; location && !hasTabOperation()) {
      sendTabOperation(RequestKind::move_tab, MoveTab{.location = *location, .direction = direction, .relative_to = relative_to});
    }
  }

  void focusDirection(PaneDirection direction) {
    if (const auto neighbor = neighboringPane(direction); neighbor != 0) {
      focusPane(neighbor);
    }
  }

  void navigateDirection(PaneDirection direction) {
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

  bool resizeDirection(PaneDirection direction) {
    auto *tab = activeTab();
    if (tab == nullptr || tab->fullscreen || !tab->layout.resize(tab->focused_pane, direction, workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics)) {
      return false;
    }

    ++view_version_.panes;
    retainLayout();

    return true;
  }

  void renameWorkspace(std::string_view name) {
    if (const auto location = active_tab_) {
      transport_.send(RenameWorkspace{nextRequest(), location->workspace, name});
    }
  }

  void input(std::uint64_t pane_id, std::string_view bytes, PaneInputSource source = PaneInputSource::keyboard) {
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
          effects_.notePaneInput({.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = pane->attached, .attachment_generation = pane->attachment_generation}, Clock::nowNanoseconds());
        }
      }

      pending_bytes = pending_bytes.subspan(count);
    }
  }

  void paste(std::uint64_t pane_id, std::string_view bytes) {
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

  void pasteHistory(std::uint64_t entry_id, bool alternate = false) {
    const auto command = history_.command(entry_id);
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

  void copyHistory(std::uint64_t entry_id) {
    clipboard_ = history_.command(entry_id);
  }

  void beginSuggestion() noexcept {
    suggestion_.begin();
  }

  void invalidateSuggestion() noexcept {
    suggestion_.invalidate();
  }

  [[nodiscard]] const SuggestionState &suggestion() const noexcept {
    return suggestion_;
  }

  bool submitSuggestion(std::string_view text) {
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

  bool beginPathPicker() {
    const auto *pane = focusedPane();
    if (!ready_ || copy_mode_.active() || pane == nullptr || !pane->attached || pane->exited || !std::string_view{pane->cwd}.starts_with('/')) {
      return false;
    }

    path_picker_.begin(pane->id, pane->cwd);
    requestPaths({});

    return true;
  }

  bool requestPaths(std::string_view query) {
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

  bool descendPath(std::size_t selection) {
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

  bool ascendPath() {
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

  void closePathPicker() noexcept {
    path_picker_.close();
  }

  bool insertPath(std::size_t selection, bool absolute) {
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

  [[nodiscard]] const PathPickerPage &pathPicker() const noexcept {
    return path_picker_;
  }

  void reportHistoryError(std::string_view message) {
    history_.setError(message);
  }

  void visitHistory(std::uint64_t entry_id) {
    visitPane(history_.entry(entry_id).pane_id);
  }

  void visitPane(std::uint64_t pane_id, std::optional<std::uint64_t> generation = {}) {
    const auto *pane = findPane(pane_id);
    if (pane != nullptr && (!generation || pane->generation == *generation)) {
      focusPane(pane_id);
    } else {
      sendOpeningRequest(RequestKind::visit_pane, OpenPane{.target = {PaneTarget::Kind::pane, pane_id}, .size = launchSize()});
    }
  }

  bool focusAgent(std::uint64_t pane_id, std::uint64_t generation) {
    const auto agent = std::ranges::find_if(agents_.entries(), [&](const auto &entry) {
      return entry.pane_id == pane_id && entry.pane_generation == generation;
    });
    if (agent == agents_.entries().end()) {
      return false;
    }

    visitPane(pane_id, generation);

    return true;
  }

  [[nodiscard]] const auto &peek() const noexcept {
    return peek_;
  }

  [[nodiscard]] const Agent<Memory> *peekAgent() const noexcept {
    if (!peek_.target()) {
      return nullptr;
    }

    return findPeekAgent(*peek_.target());
  }

  bool openPeek(PeekTarget target) {
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

  void closePeek() noexcept {
    if (peek_.target()) {
      peek_.close();
    }
  }

  bool submitPeek(std::string_view text) {
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

  void deleteHistory(std::uint64_t entry_id) {
    sendHistory(history_.erase(entry_id, nextRequest()));
  }

  void selectHistoryRow(std::size_t row) {
    if (history_.select(row)) {
      refreshHistoryDetails();
    }
  }

  void inspectHistory(bool enabled) {
    history_.setInspecting(enabled);
    refreshHistoryDetails();
  }

  void resize(std::uint64_t pane_id, TerminalSize size) {
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

  void presented(std::uint64_t pane_id, std::uint64_t frame_id) {
    auto *pane = findPane(pane_id);
    if (ready_ && pane != nullptr && pane->attached && frame_id > pane->acknowledged_frame && frame_id <= pane->screen.frameId()) {
      transport_.send(FrameAck{.pane_id = pane_id, .frame_id = frame_id});
      pane->acknowledged_frame = frame_id;
    }
  }

  void scroll(PaneScrollDelta delta) {
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

  void scrollFocused(ScrollDirection direction) {
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

  [[nodiscard]] const CopyMode &copyMode() const noexcept {
    return copy_mode_;
  }

  bool beginSelection(CopyPress press) noexcept {
    const auto *pane = focusedPane();
    if (pane == nullptr || pane->id != press.pane_id || !pane->attached) {
      return false;
    }

    return copy_mode_.beginPointer(press, copyGrid(pane->screen));
  }

  bool copySelection(std::uint64_t pane_id) {
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

  CopyPointerDecision::Outcome pointer(const CopyPointerInput &input) {
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

  bool enterCopyMode() noexcept {
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

  CopyEffect copyKey(const TerminalKey &key) {
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

  void leaveCopyMode() {
    if (auto *pane = copyPane()) {
      applyCopyPlan(copy_mode_.leave(copyGrid(pane->screen)), *pane);
    } else {
      copy_mode_.reset();
    }

    copy_search_request_ = 0;
  }

  void searchCopy(std::string_view needle) {
    const auto *pane = copyPane();
    if (pane == nullptr || !copy_mode_.active()) {
      throw EncodingError{"No copy mode owns this search"};
    }

    const SearchPane request{.request_id = nextRequest(), .pane_id = pane->id, .needle = needle};
    transport_.send(request);
    copy_search_request_ = request.request_id;
  }

  void queryHistory(std::string_view query) {
    queryHistory(query, {.author = configuration_.history.show_agent_commands ? HistoryAuthorFilter::all : HistoryAuthorFilter::human});
  }

  void queryHistory(std::string_view query, HistoryFilters filters) {
    const auto parsed = HistorySearch::parse(query, filters.failed_only);
    QueryHistory request{.request_id = nextRequest(), .query = parsed.query, .failed_only = parsed.failed_only, .author = filters.author, .match = configuration_.history.match_fts ? HistoryMatch::fts : HistoryMatch::fuzzy};
    resolveHistoryScope(request, filters.scope);
    sendHistory(history_.begin(request));
  }

  bool pageHistory(HistoryPage direction) {
    if (const auto request = history_.page(direction, nextRequest())) {
      sendHistory(*request);

      return true;
    }

    return false;
  }

  [[nodiscard]] bool historyLoading() const noexcept {
    return history_.state().phase == HistoryPhase::loading;
  }

  [[nodiscard]] const HistoryBrowser<Memory> &historyBrowser() const noexcept {
    return history_;
  }

  void toggleFullscreen() {
    if (auto *tab = activeTab()) {
      ++view_version_.panes;
      tab->fullscreen = !tab->fullscreen;
      synchronizeAttachments();
      retainLayout();
    }
  }

  void retainLayout() {
    if (!ready_ || !active_tab_) {
      return;
    }

    std::array<ClientTabLayout, maximum_tabs> layouts;
    std::size_t count = 0;
    std::size_t retained_nodes = 0;
    const auto append = [&](const Tab<Memory> &tab) {
      if (tab.layout.nodes().empty() || tab.focused_pane == 0 || retained_nodes + tab.layout.nodes().size() > maximum_retained_layout_nodes) {
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

  void setDisplayRefreshRate(std::uint16_t fps) noexcept {
    display_fps_ = std::clamp(fps, Configuration::minimum_fps, Configuration::maximum_fps);
  }

  void configureCadence() {
    const auto maximum_fps = configuration_.max_fps == 0 ? std::nullopt : std::optional{configuration_.max_fps};
    const auto interval_ns = FramePacer::resolveInterval(FramePacer::nanoseconds_per_second / display_fps_, maximum_fps);
    transport_.send(ConfigureFrameInterval{static_cast<std::uint32_t>(interval_ns)});
  }

  [[nodiscard]] Pane<Memory> *findPane(std::uint64_t pane_id) const noexcept {
    const auto found = std::find_if(panes_.begin(), panes_.end(), [&](const auto &pane) {
      return pane->id == pane_id;
    });

    return found == panes_.end() ? nullptr : found->get();
  }

  [[nodiscard]] Tab<Memory> *activeTab() const noexcept {
    return active_tab_ ? findTab(*active_tab_) : nullptr;
  }

  [[nodiscard]] Pane<Memory> *focusedPane() const noexcept {
    const auto *tab = activeTab();

    return tab == nullptr ? nullptr : findPane(tab->focused_pane);
  }

  [[nodiscard]] const auto &tabs() const noexcept {
    return tabs_;
  }

  [[nodiscard]] const auto &panes() const noexcept {
    return panes_;
  }

  [[nodiscard]] const auto &workspaces() const noexcept {
    return workspaces_.entries();
  }

  [[nodiscard]] const auto &workspaceList() const noexcept {
    return workspaces_;
  }

  [[nodiscard]] const auto &agents() const noexcept {
    return agents_.entries();
  }

  [[nodiscard]] std::uint64_t agentRevision() const noexcept {
    return agents_.revision();
  }

  [[nodiscard]] const auto &history() const noexcept {
    return history_.rows();
  }

  [[nodiscard]] std::string_view clipboard() const noexcept {
    return clipboard_;
  }

  [[nodiscard]] std::string_view notice() const noexcept {
    return notice_;
  }

  [[nodiscard]] const NotificationCenter &notifications() const noexcept {
    return notifications_;
  }

  [[nodiscard]] std::uint64_t notificationRevision() const noexcept {
    return notification_revision_;
  }

  [[nodiscard]] bool graphicsPaused(std::uint64_t pane_id) const noexcept {
    return graphics_pauses_.contains(pane_id);
  }

  [[nodiscard]] std::uint64_t graphicsRecoveryRevision() const noexcept {
    return graphics_pauses_.revision();
  }

  [[nodiscard]] std::optional<std::uint64_t> graphicsResumeDeadline() const noexcept {
    return graphics_pauses_.nextDeadline();
  }

  void resumeGraphics() {
    if (ready_) {
      graphics_pauses_.resumeDue(Clock::nowNanoseconds(), [this](std::uint64_t pane_id) {
        requestGraphicsSnapshot(pane_id);
      });
    }
  }

  void publishNotification(NotificationInput input) {
    publishNotificationAt(input, Clock::nowNanoseconds());
  }

  void reportLimit(LimitReach reach) {
    const auto recorded = countLimitReach(reach);
    if (recorded.show) {
      const auto &row = limit_reports_.row(recorded.slot);
      const auto message = LimitReports::describe(row.reach(), row.hits);
      publishNotification({.level = NotificationLevel::warning, .title = "Limit reached", .message = message.view(), .link = {}, .duration_ns = limit_notice_duration_ns});
    }
  }

  void completeAgentSound() {
    if (const auto next = sound_playback_.complete()) {
      startAgentSound(*next);
    }
  }

  bool advanceNotifications(std::uint64_t now_ns) noexcept {
    if (!notifications_.advance(now_ns)) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  bool dismissNotification(NotificationId id) noexcept {
    if (!notifications_.dismiss(id, Clock::nowNanoseconds())) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  bool activateNotification(NotificationId id) {
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

  [[nodiscard]] bool notificationTargetVisible(NotificationTarget target) const noexcept {
    const auto *tab = activeTab();

    return target.kind == NotificationTarget::Kind::pane && tab != nullptr && tab->layout.contains(target.id);
  }

  [[nodiscard]] WindowTitle windowTitle(std::string_view hostname) const {
    const auto *tab = activeTab();
    const auto *pane = focusedPane();
    WindowTitle::Tokens tokens{.workspace = {}, .tab = {}, .pane_title = pane != nullptr ? std::string_view{pane->title} : std::string_view{}, .hostname = hostname};
    if (tab != nullptr) {
      if (!tab->label.empty()) {
        tokens.tab = tab->label;
      } else {
        tokens.tab = tab->applicationName(pane);
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

  [[nodiscard]] std::string_view error() const noexcept {
    return error_;
  }

  void dismissDiagnostic() noexcept {
    error_.clear();
  }

  [[nodiscard]] bool ready() const noexcept {
    return ready_;
  }

  [[nodiscard]] std::uint64_t changedPane() const noexcept {
    return changed_pane_;
  }

  [[nodiscard]] const Configuration &configuration() const noexcept {
    return configuration_;
  }

  [[nodiscard]] ClientViewState clientViewState() const noexcept {
    return {.sidebar_visible = configuration_.sidebar_visible, .sidebar_width = sidebar_columns_, .workspace_list_collapsed = workspace_list_collapsed_, .pane_gaps = configuration_.pane_gaps, .window_title = configuration_.window_title.view()};
  }

  void configure(const Configuration &configuration) {
    configuration_ = configuration;
    sound_playback_.configure(configuration.sound);
    ++view_version_.configuration;
  }

  void setTheme(const Theme &theme) {
    if (configuration_.theme == theme) {
      return;
    }

    configuration_.theme = theme;
    ++view_version_.configuration;
  }

  [[nodiscard]] ViewVersion viewVersion() const noexcept {
    return view_version_;
  }

  void invalidateView() noexcept {
    ++view_version_.host;
  }

  void setSidebarVisible(bool visible) {
    if (configuration_.sidebar_visible != visible) {
      ++view_version_.host;
    }

    configuration_.sidebar_visible = visible;
    retainLayout();
  }

  void setSidebarWidth(float width) {
    if (configuration_.sidebar_width != width) {
      ++view_version_.host;
    }

    configuration_.sidebar_width = width;
  }

  void setHostColumns(std::uint16_t columns) noexcept {
    host_columns_ = columns;
  }

  [[nodiscard]] bool workspaceListCollapsed() const noexcept {
    return workspace_list_collapsed_;
  }

  void setWorkspaceListCollapsed(bool collapsed) {
    if (workspace_list_collapsed_ == collapsed) {
      return;
    }

    workspace_list_collapsed_ = collapsed;
    retainLayout();
  }

  [[nodiscard]] const SystemMetrics &metrics() const noexcept {
    return metrics_.sample();
  }

  [[nodiscard]] const HostMetrics &hostMetrics() const noexcept {
    return metrics_;
  }

  [[nodiscard]] const ProxyStatus &proxyStatus() const noexcept {
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

  [[nodiscard]] const Agent<Memory> *findPeekAgent(const PeekTarget &target) const noexcept {
    const auto found = std::ranges::find_if(agents_, [&](const auto &agent) {
      return agent.pane_id == target.agent.pane_id && agent.pane_generation == target.agent.pane_generation && agent.session_id == target.session;
    });

    return found == agents_.end() ? nullptr : std::addressof(*found);
  }

  void requestPeekScreen() {
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

  void openPeekDiff(const Agent<Memory> &agent) {
    const auto *row = AgentOrder::taskRow(workspaces_, agent);
    if (row == nullptr) {
      return;
    }

    constexpr std::string_view script = R"("$TELAR_BIN_PATH" worktree diff "$1" --stat; echo; "$TELAR_BIN_PATH" worktree diff "$1"; exec "${SHELL:-/bin/sh}")";
    constexpr TerminalSize size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};
    const std::array<std::string_view, 5> arguments{"sh", "-c", script, "sh", row->branch};
    sendPeekAction(LaunchWorktree{.worktree = row->id, .label = "diff", .size = size, .launch = {.cwd = row->path.empty() ? std::string_view{"/"} : std::string_view{row->path}, .arguments = arguments}}, agent.pane_id);
  }

  std::optional<Change> failPeekRequest(const Pending &request, const RequestFailed &failure) {
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

  void resolveHistoryScope(QueryHistory &request, HistoryScope scope) const {
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
      fallback = workspaces_.projectOf(tab->location.workspace.id);
    } else if (const auto *row = workspaces_.worktree(tab->location.workspace.id)) {
      fallback = row->source;
    }

    return MachineBookmark{.location = tab->location, .pane_id = tab->focused_pane, .fallback_workspace = fallback};
  }

  void releaseMachinePresentation() noexcept {
    panes_.clear();
    active_tab_.reset();
    requested_workspace_.reset();
    copy_mode_.reset();
    copy_search_request_ = 0;
    history_.suspend();
    path_picker_.close();
    suggestion_.invalidate();
    graphics_pauses_.reset();
    editor_opening_.reset();
    for (auto &tab : tabs_) {
      tab->loaded = false;
      tab->loading = false;
    }

    ++view_version_.workspace;
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
        selectTab(location);
        sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = location.workspace});
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
    const auto arguments = launch_arguments_.empty() ? std::span<const std::string_view>{default_shell} : std::span<const std::string_view>{launch_arguments_};

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
    if constexpr (std::same_as<Message, GraphicsSnapshot> || std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsImageChunk> || std::same_as<Message, GraphicsPlacementMessage> || std::same_as<Message, GraphicsDeleteImage> || std::same_as<Message, GraphicsDeletePlacement>) {
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

  template <typename Message>
  Change applyGraphics(const Message &message) {
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
        visitPane(message.pane_id, message.pane_generation);
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

    if ((presented_ || leave_pending_) && (!active_tab_ || (requested_workspace_ && sameWorkspace(*requested_workspace_, message.workspace))) && !message.tabs.empty()) {
      requested_workspace_.reset();
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
      auto &tab = ensureTab(saved.location);
      tab.layout.restore(saved.nodes);
      tab.focused_pane = saved.focused_pane;
      tab.fullscreen = saved.fullscreen;
      tab.workspace_active = saved.workspace_active;
    }

    if (presented_) {
      selectTab(*message.active_tab);
      sendSnapshotRequest(RequestWorkspaceSnapshot{.workspace = message.active_tab->workspace});
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

      if (request->kind == RequestKind::restore_machine && request->fallback_workspace && message.code == FailureCode::pane_not_found) {
        sendOpeningRequest(RequestKind::open_default, OpenPane{.target = {.kind = PaneTarget::Kind::workspace, .id = *request->fallback_workspace}, .size = launchSize()});

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
    reply.status = ClientCommandStatus::applied;
    reply.text = {};
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
  Change executeCommand(const ClientCommand &message, CompleteClientCommand &reply, Handler &handler) {
    switch (message.action) {
    case ClientAction::layout_get:
      reply.text = exportLayout();

      return Change::none;
    case ClientAction::layout_apply:
      importLayout(message.text);

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
      reply.status = ClientCommandStatus::admitted;

      return Change::clipboard;
    case ClientAction::notification_dismiss:
      if (!dismissNotification(NotificationId{message.target_id})) {
        throw EncodingError{"NotificationNotFound"};
      }

      return Change::notification;
    case ClientAction::client_copy_mode:
      if (!copy_mode_.active() && !enterCopyMode()) {
        throw EncodingError{"Copy mode is unavailable"};
      }

      return Change::copy_mode;
    default:
      handler(message, reply);

      return Change::none;
    }
  }

  void executeNavigationCommand(const ClientCommand &message, CompleteClientCommand &reply) {
    switch (message.action) {
    case ClientAction::tab_next:
    case ClientAction::tab_previous:
      selectTabOffset(message.action == ClientAction::tab_next ? 1 : -1);
      reply.target_id = active_tab_ ? active_tab_->tab_id : 0;
      break;
    case ClientAction::workspace_select:
      if (std::ranges::none_of(workspaces_, [&](const auto &workspace) {
            return workspace.location.kind == WorkspaceLocation::Kind::workspace && workspace.location.id == message.target_id;
          })) {
        throw EncodingError{"Workspace does not belong to this client"};
      }

      selectWorkspace({WorkspaceLocation::Kind::workspace, message.target_id});
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::tab_create:
      if (createTab(message.text) != TabCreationOutcome::requested) {
        throw EncodingError{"ClientBusy"};
      }

      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::tab_select: {
      const auto tab = std::ranges::find_if(tabs_, [&](const auto &entry) {
        return entry->location.tab_id == message.target_id;
      });
      if (tab == tabs_.end()) {
        throw EncodingError{"Tab does not belong to this client"};
      }

      selectTab((*tab)->location);
    } break;
    default:
      throw EncodingError{"Invalid navigation command"};
    }
  }

  void admitPaneSplit(ClientLayoutAxis axis, CompleteClientCommand &reply) {
    if (!split(axis)) {
      throw EncodingError{"PaneCreationUnavailable"};
    }

    reply.status = ClientCommandStatus::admitted;
  }

  void executePaneCommand(const ClientCommand &message, CompleteClientCommand &reply) {
    switch (message.action) {
    case ClientAction::pane_create:
      admitPaneSplit(ClientLayoutAxis::horizontal, reply);
      break;
    case ClientAction::pane_split:
      if (message.text != "horizontal" && message.text != "vertical") {
        throw EncodingError{"Invalid split axis"};
      }

      focusCommandPane(message.target_id);
      admitPaneSplit(message.text == "horizontal" ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical, reply);
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
        throw EncodingError{"Pane resize is unavailable"};
      }
    } break;
    case ClientAction::pane_fullscreen:
      focusCommandPane(message.target_id);
      toggleFullscreen();
      reply.value = activeTab()->fullscreen;
      break;
    case ClientAction::pane_scroll:
      if (message.value < std::numeric_limits<std::int32_t>::min() || message.value > std::numeric_limits<std::int32_t>::max()) {
        throw EncodingError{"Invalid scroll delta"};
      }

      if (!commandPane(message.target_id).attached) {
        throw EncodingError{"Pane viewport is unavailable"};
      }

      scroll({.pane_id = message.target_id, .rows = -message.value});
      break;
    case ClientAction::pane_copy:
      if (!commandPane(message.target_id).attached) {
        throw EncodingError{"Copy pane is not attached"};
      }

      transport_.send(CopyRangeParser::parse(message.target_id, message.text));
      reply.status = ClientCommandStatus::admitted;
      break;
    default:
      throw EncodingError{"Invalid pane command"};
    }
  }

  Change executeSidebarCommand(const ClientCommand &message, CompleteClientCommand &reply) {
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

  static PaneDirection parseDirection(std::string_view text) {
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

  [[nodiscard]] const Pane<Memory> &commandPane(std::uint64_t identity) const {
    const auto *pane = findPane(identity);
    if (pane == nullptr || !active_tab_ || !sameTab(pane->location, *active_tab_)) {
      throw EncodingError{"Pane does not belong to the active tab"};
    }

    return *pane;
  }

  void focusCommandPane(std::uint64_t identity) {
    focusPane(commandPane(identity).id);
  }

  std::string_view exportLayout() {
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

  void importLayout(std::string_view token) {
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

  void validateLayoutMembership(const TabLayoutPreset &preset) const {
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

  std::size_t orderedTabs(std::array<Tab<Memory> *, maximum_tabs> &ordered) const noexcept {
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

  std::uint64_t neighboringPane(PaneDirection direction) {
    auto *tab = activeTab();
    if (tab == nullptr) {
      return 0;
    }

    return tab->layout.focusTarget(workbench_geometry_.cellArea(), workbench_geometry_.layout_metrics, {.pane_id = tab->focused_pane, .direction = direction, .fullscreen = tab->fullscreen});
  }

  Change apply(const PaneFocusCommand &message) {
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
  Memory &memory_;
  Transport &transport_;
  [[no_unique_address]] Effects effects_;
  SoundPlayback sound_playback_;
  GraphicsBudget graphics_budget_;
  GraphicsPauses graphics_pauses_;
  LimitReports limit_reports_;
  static constexpr std::uint64_t limit_notice_duration_ns = 8'000'000'000;
  Vector<Owned<Pane<Memory>, Memory>, Memory> panes_;
  Vector<Owned<Tab<Memory>, Memory>, Memory> tabs_;
  WorkspaceReplica<Memory> workspaces_;
  AgentReplica<Memory> agents_;
  AgentAcknowledgement agent_acknowledgement_;
  NotificationCenter notifications_;
  std::uint64_t notification_revision_ = 0;
  HistoryBrowser<Memory> history_;
  PeekScreen<Memory> peek_;
  PathPickerPage path_picker_;
  SuggestionState suggestion_;
  Vector<Byte, Memory> decode_;
  String<Memory> clipboard_;
  String<Memory> notice_;
  String<Memory> error_;
  String<Memory> command_response_;
  String<Memory> launch_cwd_;
  Vector<String<Memory>, Memory> argument_storage_;
  Vector<std::string_view, Memory> launch_arguments_;
  std::array<Pending, maximum_pending> pending_;
  std::size_t pending_count_ = 0;
  std::optional<TabLocation> active_tab_;
  std::optional<WorkspaceLocation> requested_workspace_;
  std::optional<TabLocation> deferred_tab_;
  std::optional<MachineBookmark> left_machine_;
  std::uint64_t request_id_ = 0;
  std::uint64_t attachment_generation_ = 0;
  std::uint64_t changed_pane_ = 0;
  WorkbenchGeometry workbench_geometry_;
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
