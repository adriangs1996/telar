module;
#include "tbc/annotations.hpp"

export module telar.gui.application:session;

import std;
import telar.tbc;

import :host_effects;
import :workspace_replica;
import telar.gui.foundation.core;
import telar.gui.graphics.texture_cache;
import telar.gui.graphics.pauses;
import telar.gui.features.history;
import telar.gui.input.copy_pointer;
import telar.gui.foundation.keys;
import telar.gui.presentation.tab_drop;
import :sound_playback;
import telar.gui.foundation.model;
import telar.gui.layout.snapshots;
import telar.gui.links.path_expansion;
import telar.gui.links.cell_links;
import telar.gui.features.paths;
import telar.gui.features.peek;
import telar.gui.foundation.system;
import :client_view_state;
import :sidebar;
import telar.gui.presentation.application_mark;
import telar.gui.features.palette;
import telar.config.client;
import telar.config.runtime;
import telar.gui.foundation.terminal;
import telar.gui.input.copy_mode;
import telar.gui.prompt.line;
import telar.base.diagnostics;
import telar.base.text;
import telar.gui.prompt.layout;
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
import telar.base.memory.allocators;
import telar.gui.prompt.routing;
import telar.gui.prompt.editor;
import telar.gui.presentation.notification_center;
import telar.gui.foundation.text;
import telar.shell.syntax;
import telar.gui.prompt.completion;

// Interface: application/session.cppm
export {
  namespace telar::gui::application {

    enum class Change : std::uint8_t {
      none,
      model,
      // The sidebar was shown, hidden or resized, or its workspace list collapsed or expanded.
      sidebar,
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
      document,
    };

    // Whether the shell runs a command word: asked of the runtime, pending until it answers,
    // unknown where it cannot tell (a remote shell, names it never reported).
    enum class CommandPresence : std::uint8_t {
      unknown,
      pending,
      found,
      missing,
    };

    // The clock a session reads, monotonic and in nanoseconds.
    using MonotonicNow = std::uint64_t (*)() noexcept;

    class Session {
      // The use cases of application::<feature> reach the members below through it.
      friend struct Access;

    public:
      static constexpr std::size_t decode_capacity = std::size_t{2} * 1024 * 1024;
      static constexpr std::size_t maximum_tabs = 256;
      static constexpr std::size_t maximum_workspace_tabs = 64;
      static constexpr std::size_t maximum_panes = maximum_tabs * PaneLayout::maximum_panes;
      static constexpr std::size_t maximum_pending = 256;
      static constexpr std::size_t maximum_retained_layout_nodes = 511;
      static constexpr std::size_t input_chunk_size = 65536;
      // A viewport past any bottom: the runtime follows the output.
      static constexpr std::uint32_t follow_output = std::numeric_limits<std::uint32_t>::max();
      static constexpr std::uint16_t default_sidebar_columns = SidebarColumns::minimum_width;
      static constexpr std::size_t maximum_launch_arguments = 64;

      // The session keeps the allocator and the transport, region `a`, which also holds what its replies and
      // requests view of the session's own panes, workspaces and responses.
      Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<MonotonicNow, tbc::lt::static_storage> now = &system::AwakeClock::nowNanoseconds);

      // The session also keeps `effects`, region `a`.
      Session(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<RuntimeTransport&, tbc::lt::a> transport, tbc::view<HostEffects&, tbc::lt::a> effects, tbc::view<MonotonicNow, tbc::lt::static_storage> now = &system::AwakeClock::nowNanoseconds);

      Session(const Session&) = delete;
      Session& operator=(const Session&) = delete;

      void setLaunch(const Launch& launch);

      void setLaunchDirectory(std::string_view directory);

      void setLaunchArguments(std::span<const std::string_view> arguments);

      void setRestoreLayout(bool enabled) noexcept;

      // `reads_rows`: the runtime reads its scrollback's rows by stable number (schema cqp00003).
      void connected(std::uint64_t identity, bool reads_rows = true);

      [[nodiscard]] bool requestsPending() const noexcept;

      [[nodiscard]] bool presented() const noexcept;

      void setPresented(bool presented);

      bool settlePresentation();

      void disconnected() noexcept;

      Change consume(std::span<const Byte> payload);

      Change consume(std::span<const Byte> payload, const ClientCommandHandler& handler);

      void selectTab(TabLocation location);

      bool selectWorkspace(WorkspaceLocation location);

      void selectWorkspaceIndex(std::size_t index);

      void focusPane(std::uint64_t pane_id);

      bool openWorktree(std::uint64_t identity);

      bool leaveWorktree();

      std::size_t forgetGoneWorktrees();

      TabCreationOutcome createTab(std::string_view label = {});

      TabCreationOutcome createCommandTab(const runtime::config::CommandTabView& command);

      // Without a directory the workspace starts where the focused pane is.
      void createWorkspace(WorkspaceDraft draft);

      // Opens `path` in an editor. A relative path is anchored at the cwd of pane `source_id`,
      // after `environment` expands it.
      template <PathEnvironment Environment>
      TBC_GENERIC void openFile(const FilePath& path, std::string_view executable, const Environment& environment, std::optional<std::uint64_t> source_id = {}) {
        const auto base = fileBase(path, executable, source_id);
        const auto anchored = base ? PathExpansion::expand({.text = path.text(), .base = *base}, environment) : PathExpansion::PathText{};

        openAnchoredFile(path, executable, anchored.view(), source_id);
      }

      void setWorkbenchGeometry(WorkbenchGeometry geometry) noexcept;

      void setAttachmentReservation(std::optional<PaneBottomReservation> reservation);

      [[nodiscard]] const WorkbenchGeometry& workbenchGeometry() const noexcept;

      bool split(ClientLayoutAxis axis);

      bool closePane(std::uint64_t pane_id);

      void closeTab(TabLocation location);

      void renameTab(std::string_view label);

      void selectTabIndex(std::size_t index);

      void selectTabOffset(std::int32_t offset);

      void moveTab(TabMoveDirection direction, std::optional<std::uint64_t> relative_to = {});

      [[nodiscard]] bool tabOperationPending() const noexcept;

      [[nodiscard]] bool requestTabMove(const TabDragMove& move);

      void focusDirection(PaneDirection direction);

      void navigateDirection(PaneDirection direction);

      bool resizeDirection(PaneDirection direction);

      void renameWorkspace(std::string_view name);

      void input(std::uint64_t pane_id, std::string_view bytes, PaneInputSource source = PaneInputSource::keyboard);

      // Runs a command at the pane's prompt. A runtime that takes commands types it there itself and
      // keeps this text for the command's history; an older one (schema cqp00002) gets it pasted,
      // then Enter, and reads the command back from the screen.
      void runCommand(std::uint64_t pane_id, std::string_view text);

      // Typing returns a scrolled pane to its live end, where the output follows.
      void followLiveEnd(Pane<Memory>& pane);

      void notePaneInput(const Pane<Memory>& pane);

      // ---- telar's command editor -----------------------------------------------------------

      [[nodiscard]] prompt::Surface promptSurface(std::uint64_t pane_id) const noexcept;

      // ---- scrollback rows beyond the screen ----------------------------------------------------

      // Whether the runtime sends rows of a scrollback apart from its screen, for a view that
      // scrolls by pixels or folds commands. Without them the view moves by whole rows.
      [[nodiscard]] bool readsRows() const noexcept;

      // Asks for the rows from stable row `first` to `last` the pane holds neither on its screen
      // nor in its cache, a request at a time while requests are free.
      void requestRows(std::uint64_t pane_id, std::uint64_t first, std::uint64_t last);

      // The rows the scrollback dropped from its top since the pane's view last asked: the view
      // moves up by as many to keep showing the same rows.
      [[nodiscard]] std::uint64_t takeDroppedRows(std::uint64_t pane_id) noexcept;

      // ---- folded commands ------------------------------------------------------------------------

      // The stable number of a block's first row, which names it while rows above it are dropped.
      [[nodiscard]] static std::uint64_t blockKey(const Pane<Memory>& pane, std::size_t index) noexcept;

      [[nodiscard]] bool folded(std::uint64_t pane_id, std::size_t index) const noexcept;

      // Folds the output of block `index`, or unfolds it. Only a runtime that sends rows apart from
      // the screen can show what follows a fold.
      void fold(std::uint64_t pane_id, std::size_t index, bool fold);

      // Folds every block but a running one, or unfolds them all.
      void foldAll(std::uint64_t pane_id, bool fold);

      // The rows of block `index`'s output, from under its prompt to above the next prompt, or to
      // the live prompt or the scrollback's end for the last; empty when it printed nothing.
      [[nodiscard]] static std::pair<std::uint32_t, std::uint32_t> blockRows(const Pane<Memory>& pane, std::size_t index) noexcept;

      // ---- command blocks, selected from the editor -------------------------------------------

      [[nodiscard]] std::optional<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept;

      // Selects the block at `index`, shown from the top of the pane, or none: the pane's live end.
      void selectBlock(std::uint64_t pane_id, std::optional<std::size_t> index);

      // prefix+[ where telar's editor stands in for the prompt: the last command block, selected,
      // instead of copy mode from the live end.
      bool enterBlocks();

      // The pane whose editor took text from outside the keyboard (a paste, a history entry, a
      // suggestion, a path) since the last call, for its view to show it.
      [[nodiscard]] std::optional<std::uint64_t> takePromptWrite() noexcept;

      // Whether a block was selected or left, or copy mode began on one, since the last call.
      [[nodiscard]] bool takeBlockChange() noexcept;

      // Whether text was written to the clipboard since the last call, as copying a command does.
      [[nodiscard]] bool takeClipboardWrite() noexcept;

      // Whether text meant for the pane belongs in telar's editor instead.
      [[nodiscard]] bool editsPrompt(std::uint64_t pane_id) const noexcept;

      // Whether the terminal's cursor marks a place no key reaches, so it is not drawn: at the
      // prompt telar's editor has the keys; while a command runs, typing queues the next one unless
      // the program seems to ask for input (its cursor past a line's start, as routing judges); and
      // between a command's end and the next prompt the editor is about to take its row. Drawing it
      // there flashes a block for a frame or two under every quick command's output.
      [[nodiscard]] bool hidesTerminalCursor(std::uint64_t pane_id) const noexcept;

      [[nodiscard]] std::span<const std::string> promptHistory() const noexcept;

      [[nodiscard]] const prompt::Line* promptLine(std::uint64_t pane_id) const noexcept;

      // A key for the pane's editor or queue. `terminal` hands it back to the terminal.
      prompt::Outcome promptKey(std::uint64_t pane_id, const prompt::KeyPress& key);

      // Whether the pane's shell runs `word`, for the editor to mark a command that does not
      // exist. Asks the runtime the first time and answers pending until it replies; a remote
      // shell's commands are unknown. Forgotten after each command and change of directory.
      CommandPresence commandPresence(std::uint64_t pane_id, std::string_view word);

      // Whether a pane's header changed with its shell's state since the last call.
      [[nodiscard]] bool takeChromeChange() noexcept;

      // Scrolls the pane so `row`, counted from the top of its scrollback, is the first shown.
      void scrollToRow(std::uint64_t pane_id, std::uint32_t row);

      // Text an input method committed or a paste, into the editor. Controls other than newline
      // and tab are dropped: they would act on the shell instead of being written.
      void promptText(std::uint64_t pane_id, std::string_view text);

      void paste(std::uint64_t pane_id, std::string_view bytes);

      // A paste straight to the terminal, framed when the program asked for bracketed paste.
      void pasteBytes(std::uint64_t pane_id, std::string_view bytes);

      void visitPane(std::uint64_t pane_id, std::optional<std::uint64_t> generation = {});

      bool focusAgent(std::uint64_t pane_id, std::uint64_t generation);

      bool focusListedPane(std::uint64_t pane_id, std::uint64_t generation);

      void resize(std::uint64_t pane_id, TerminalSize size);

      void presented(std::uint64_t pane_id, std::uint64_t frame_id);

      void scroll(PaneScrollDelta delta);

      void scrollFocused(ScrollDirection direction);

      [[nodiscard]] const CopyMode& copyMode() const noexcept;

      bool beginSelection(CopyPress press) noexcept;

      bool copySelection(std::uint64_t pane_id);

      CopyPointerDecision::Outcome pointer(const CopyPointerInput& input);

      bool enterCopyMode() noexcept;

      CopyEffect copyKey(const TerminalKey& key);

      void leaveCopyMode();

      void searchCopy(std::string_view needle);

      // The search typed so far ends: its matches stay for n and N, from wherever they took the
      // cursor.
      void finishCopySearch() noexcept;

      // What the copy-mode search looks for, whether an answer is awaited, and how its matches
      // stand: how many, which the cursor is on, and whether there were more than it kept.
      struct CopySearchState {
        std::string_view query;
        bool searching = false;
        std::size_t count = 0;
        std::size_t index = 0;
        bool truncated = false;
      };

      [[nodiscard]] CopySearchState copySearch() const noexcept;

      // The next match or the one before, as n and N go.
      void stepCopyMatch(bool forward);

      // The command whose output the copy-mode search reads, while it reads only that output.
      [[nodiscard]] std::optional<std::size_t> copySearchBlock() const noexcept;

      // Whether a search can be confined to a command's output, as one began from a command can.
      [[nodiscard]] bool copySearchScopes() const noexcept;

      // Between that command's output and the whole scrollback.
      void toggleCopySearchScope() noexcept;

      // Whether a key asked for the scrollback search since the last call.
      [[nodiscard]] bool takeSearchRequest() noexcept;

      void toggleFullscreen();

      void retainLayout();

      void setDisplayRefreshRate(std::uint16_t fps) noexcept;

      void configureCadence();

      [[nodiscard]] Pane<Memory>* findPane(std::uint64_t pane_id) const noexcept;

      [[nodiscard]] Tab<Memory>* activeTab() const noexcept;

      [[nodiscard]] Pane<Memory>* focusedPane() const noexcept;

      [[nodiscard]] const Vector<Owned<Tab<Memory>, Memory>, Memory>& tabs() const noexcept;

      [[nodiscard]] const Vector<Owned<Pane<Memory>, Memory>, Memory>& panes() const noexcept;

      [[nodiscard]] const Vector<Workspace<Memory>, Memory>& workspaces() const noexcept;

      [[nodiscard]] const WorkspaceReplica<Memory>& workspaceList() const noexcept;

      [[nodiscard]] const Vector<Agent<Memory>, Memory>& agents() const noexcept;

      [[nodiscard]] std::uint64_t agentRevision() const noexcept;

      [[nodiscard]] std::span<const ListedPane> paneList() const noexcept;

      [[nodiscard]] std::uint64_t paneListRevision() const noexcept;

      [[nodiscard]] std::string_view clipboard() const noexcept;

      [[nodiscard]] const NotificationCenter& notifications() const noexcept;

      [[nodiscard]] std::uint64_t notificationRevision() const noexcept;
      // Changes with what a pane's header and its tab show: title, directory, program, progress,
      // git, the shell's host and link, and whether a tab's panes are loaded. ViewVersion leaves
      // these out on purpose: they never move a link under the pointer.
      [[nodiscard]] std::uint64_t chromeRevision() const noexcept;

      [[nodiscard]] bool graphicsPaused(std::uint64_t pane_id) const noexcept;

      [[nodiscard]] std::uint64_t graphicsRecoveryRevision() const noexcept;

      [[nodiscard]] std::optional<std::uint64_t> graphicsResumeDeadline() const noexcept;

      void resumeGraphics();

      void publishNotification(NotificationInput input);

      void reportLimit(LimitReach reach);

      void completeAgentSound();

      bool advanceNotifications(std::uint64_t now_ns) noexcept;

      bool dismissNotification(NotificationId id) noexcept;

      bool activateNotification(NotificationId id);

      [[nodiscard]] bool notificationTargetVisible(NotificationTarget target) const noexcept;

      [[nodiscard]] WindowTitle windowTitle(std::string_view hostname) const;

      [[nodiscard]] std::string_view error() const noexcept;

      void dismissDiagnostic() noexcept;

      [[nodiscard]] bool ready() const noexcept;

      // The view measured an inline document in `rows` rows of its own.
      bool measureInline(std::uint64_t pane_id, std::uint64_t id, std::uint32_t rows);

      [[nodiscard]] std::uint64_t changedPane() const noexcept;

      [[nodiscard]] const Configuration& configuration() const noexcept;

      [[nodiscard]] ClientViewState clientViewState() const noexcept;

      void configure(const Configuration& configuration);

      // Tells the runtime whether telar's editor stands in for the shell's prompt: the shells of the
      // panes it opens from now on print no prompt of their own. A cqp00002 runtime cannot hear it.
      void configureShellPrompt();

      void setTheme(const Theme& theme);

      [[nodiscard]] ViewVersion viewVersion() const noexcept;

      void invalidateView() noexcept;

      void setSidebarVisible(bool visible);

      void setSidebarWidth(float width);

      void setHostColumns(std::uint16_t columns) noexcept;

      [[nodiscard]] bool workspaceListCollapsed() const noexcept;

      void setWorkspaceListCollapsed(bool collapsed);

      [[nodiscard]] const SystemMetrics& metrics() const noexcept;

      [[nodiscard]] const HostMetrics& hostMetrics() const noexcept;

      [[nodiscard]] const ProxyStatus& proxyStatus() const noexcept;

    private:
      // The cwd a relative `path` is anchored at, after checking that the file can be opened.
      std::optional<std::string_view> fileBase(const FilePath& path, std::string_view executable, std::optional<std::uint64_t> source_id) const;

      // Opens `path` once `fileBase` admitted it, with a relative path already `anchored`.
      void openAnchoredFile(const FilePath& path, std::string_view executable, std::string_view anchored, std::optional<std::uint64_t> source_id);

      // Encodes `message` into the storage the transport lends.
      template <typename Message>
      std::span<const Byte> encode(const Message& message);

      template <typename Message>
      void send(const Message& message);

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

      [[nodiscard]] TerminalSize launchSize() const;

      template <typename Request>
        requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
      void sendOpeningRequest(RequestKind kind, Request request, TabLocation location = TabLocation(), std::optional<std::uint64_t> fallback_workspace = std::nullopt);

      template <typename Request>
        requires(std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot>)
      void sendSnapshotRequest(Request request);

      bool completeRequest(RequestKind kind, std::uint64_t request_id) noexcept;

      [[nodiscard]] bool hasPaneOperation() const noexcept;

      [[nodiscard]] std::optional<SplitSizes> splitSizes(Tab<Memory>& tab, std::uint64_t pane_id, ClientLayoutAxis axis) noexcept;

      bool requestPaneSplit(std::uint64_t pane_id, ClientLayoutAxis axis, Launch launch);

      void recoverSplit(const Pending& request);

      void resizeVisiblePanes(Tab<Memory>& tab);

      Pane<Memory>& allocateSplitPane(const Pending& request, const PaneOpened& message);

      Change adoptSplit(const Pending& request, const PaneOpened& message);

      [[nodiscard]] bool hasTabOperation() const noexcept;

      template <typename Request>
      void sendTabOperation(RequestKind kind, Request request);

      // Sends `request` under a new pending id of `kind`, once `fill` recorded in the pending entry
      // what the reply will need; a request the transport refuses leaves nothing pending.
      template <typename Request, typename Fill>
      void sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id, Fill&& fill);

      template <typename Request>
      void sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id = 0);

      template <typename Value>
      static void reserveAppend(Vector<Value, Memory>& values, std::size_t maximum);

      TabCreationOutcome requestTabCreation(std::string_view label, std::span<const std::string_view> arguments);

      std::uint64_t nextRequest() noexcept;

      std::uint64_t pending(RequestKind kind, std::uint64_t pane_id = 0, ClientLayoutAxis axis = ClientLayoutAxis::horizontal);

      std::optional<Pending> complete(std::uint64_t request_id) noexcept;

      [[nodiscard]] Tab<Memory>* findTab(TabLocation location) const noexcept;

      Tab<Memory>& ensureTab(TabLocation location);

      Pane<Memory>& ensurePane(std::uint64_t pane_id, TabLocation location);

      void setPaneFocus(Tab<Memory>& tab, std::uint64_t pane_id);

      void openDefault();

      [[nodiscard]] std::optional<MachineBookmark> machineBookmark() const noexcept;

      bool recoverMissingWorkspacePane(const Pending& request, const RequestFailed& failure);

      void handoffPane(std::uint64_t pane_id, std::optional<std::uint64_t> fallback_workspace);

      void handoffWorkspace(PaneTarget target, std::optional<std::uint64_t> fallback_workspace);

      void releaseWorkspacePresentation() noexcept;

      void restoreMachinePresentation();

      void openRestoredWorkspace(TabLocation location);

      void stageWorkspaceLayout(Tab<Memory>& tab);

      void restoreCanonicalLayout(Tab<Memory>& tab);

      void createEditorTab(const EditorTarget& target);

      void splitEditorPane(const EditorRequest& request);

      void confirmAttachment(Pane<Memory>& pane);

      [[nodiscard]] Launch defaultLaunch() const noexcept;

      void synchronizeAttachments();

      void acknowledgeFocusedAgent();

      void prepareDetach(std::uint64_t pane_id);

      Pane<Memory>* copyPane() noexcept;

      [[nodiscard]] CopyPointerAuthority pointerAuthority(const CopyPointerInput& input) const noexcept;

      void applyCopyPlan(const CopyPlan& plan, Pane<Memory>& pane);

      void applyPointerMotion(const CopyPointerDecision& decision, bool released, Pane<Memory>& pane);

      Change apply(const PaneMatches& message);

      Change apply(const PaneFrame& message);

      // The rows the folded blocks hide, from their stable numbers; folds whose blocks are gone
      // are forgotten.
      void refreshFolds(Pane<Memory>& pane);

      template <typename Message>
      Change dispatchMessage(std::span<const Byte> payload, DecodeStorage& storage, const ClientCommandHandler& handler);

      template <typename Message, typename Source = std::nullptr_t>
      Change applyGraphics(const Message& message, Source source = nullptr);

      void recoverRuntime(std::string_view reason);

      template <typename Message>
      void sendGraphics(const Message& message);

      void requestGraphicsSnapshot(std::uint64_t pane_id);

      LimitReports::Recorded countLimitReach(LimitReach reach);

      void pauseGraphics(std::uint64_t pane_id, const GraphicsLimitError& error);

      void showGraphicsPause(LimitReports::Slot slot, std::uint64_t pane_id);

      [[nodiscard]] BoundedText<max_notification_title_bytes> graphicsPauseTitle(std::uint64_t pane_id) const;

      void forgetClosedGraphics();

      Change apply(const GraphicsSnapshot& message);

      Change apply(const GraphicsImage& message);

      [[nodiscard]] bool supportsSharedGraphics() const noexcept;

      Change apply(const GraphicsSharedImage& message);

      Change apply(const GraphicsImageChunk& message);

      Change apply(const GraphicsPlacementMessage& message);

      Change apply(const GraphicsDeleteImage& message);

      Change apply(const GraphicsDeletePlacement& message);

      Change apply(const PaneOpened& message);

      Change apply(const TabCreated& message);

      Change apply(const TabSnapshot& message);

      Change apply(const WorkspaceSnapshot& message);

      Change apply(const WorkspaceList& message);

      Change apply(const ClientLayoutSnapshot& message);

      Change apply(const TabClosed& message);

      [[nodiscard]] std::optional<TabLocation> tabAfterRemoval(TabLocation closing, std::uint16_t position) const noexcept;

      void discardTab(TabLocation location);

      // The one way a pane leaves the model, whichever message removes it: nothing it started keeps
      // waiting and nothing kept by its id outlives it.
      template <typename Removed>
      void removePanes(Removed removed);

      void forgetPane(std::uint64_t pane_id) noexcept;

      void cancelPaneRequests(std::uint64_t pane_id) noexcept;

      Change apply(const TabRenamed& message);

      Change apply(const TabMoved& message);

      Change apply(const PaneExited& message);

      Change apply(const PaneTitle& message);

      Change apply(const PaneCwd& message);

      Change apply(const PaneForeground& message);

      Change apply(const PaneClipboard& message);

      Change apply(const PaneProgress& message);

      Change apply(const PaneGit& message);

      Change apply(const PaneShell& message);

      Change apply(const CommandSpec& message);

      Change apply(const PaneBlocks& message);

      // A document arrives in parts of one revision, in order; it shows once whole and valid. A
      // newer revision, or a part out of order, starts over.
      Change apply(const PaneDocument& message);

      // A document that stands for rows of the scrollback arrives in parts like the pane's own; once
      // whole, a part with no bytes only moves its rows, and size 0 withdraws it.
      Change applyInline(Pane<Memory>& pane, const PaneDocument& message);

      Change apply(const PaneScrollback& message);

      Change apply(const PaneRows& message);

      Change apply(const AgentSnapshot& message);

      Change apply(const PaneList& message);

      Change apply(const HistoryResults& message);

      Change apply(const HistoryOutput& message);

      Change apply(const HistoryPruned& message);

      Change apply(const CompletionWords& message);

      Change apply(const PathResults& message);

      Change apply(const CommandSuggestion& message);

      Change apply(const SystemMetrics& message);

      Change apply(const ProxyStatus& message);

      Change apply(const RequestFailed& message);

      Change apply(const EditorOpened& message);

      Change reportLinkFailure(std::string_view message);

      Change apply(const RequestCompleted& message);

      Change apply(const PaneText& message);

      Change apply(const ResyncRequired& message);

      Change apply(const Notification& message);

      void publishNotificationAt(NotificationInput input, std::uint64_t now_ns);

      [[nodiscard]] bool deliverHostNotification(const NotificationInput& input) noexcept;

      Change apply(const AgentSoundNotification& message);

      void startAgentSound(AgentSound sound);

      Change apply([[maybe_unused]] const RuntimeStopping& message);

      Change apply(const ClientCommand& message, const ClientCommandHandler& handler);

      Change executeCommand(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply, const ClientCommandHandler& handler);

      // A command that changes nothing is `applied`,
      // one that starts a change is `admitted`, and the target stays the one the
      // CLI sent, which the runtime matches the completion by.
      void executeNavigationCommand(const ClientCommand& message, CompleteClientCommand& reply);

      void admitPaneSplit(ClientLayoutAxis axis, CompleteClientCommand& reply);

      void executePaneCommand(const ClientCommand& message, CompleteClientCommand& reply);

      Change executeSidebarCommand(const ClientCommand& message, CompleteClientCommand& reply);

      static PaneDirection parseDirection(std::string_view text);

      [[nodiscard]] const Pane<Memory>& commandPane(std::uint64_t identity) const;

      void focusCommandPane(std::uint64_t identity);

      tbc::view<std::string_view, tbc::lt::a> exportLayout();

      void importLayout(std::string_view token);

      void validateLayoutMembership(const TabLayoutPreset& preset) const;

      std::size_t orderedTabs(tbc::view<std::array<Tab<Memory>*, maximum_tabs>&, tbc::lt::a> ordered) const noexcept;

      std::uint64_t neighboringPane(PaneDirection direction);

      Change apply(const PaneFocusCommand& message);

      Configuration configuration_;
      ViewVersion view_version_;

      struct LineEntry {
        prompt::Line line;
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
      std::optional<prompt::Outcome> blockKey(std::uint64_t pane_id, LineEntry& entry, const prompt::KeyPress& key);

      // The shown row at the view's top: as its view says, or as the runtime's view puts it.
      [[nodiscard]] static std::uint64_t shownTop(const Pane<Memory>& pane) noexcept;

      // Scrolls the pane so that shown row `display`, folds counted, is the view's top.
      void scrollToShownRow(const Pane<Memory>& pane, std::uint64_t display);

      // Remembers the view's top before a jump, dropping the jumps Ctrl-O had gone back past.
      void recordJump(const Pane<Memory>& pane, LineEntry& entry);

      // Back to where the last jump left from, or forward again; the view's top goes there.
      void jumpBack(const Pane<Memory>& pane, LineEntry& entry, bool back);

      // Copy mode on a block's output, at its first row, with the scrollback search asked for and
      // confined to that output.
      void searchBlockOutput(Pane<Memory>& pane, std::size_t index);

      // The rows of a block's output: from under its command to above the next block's prompt, or
      // the live prompt's for the last one.
      [[nodiscard]] std::pair<std::uint32_t, std::uint32_t> blockOutput(const Pane<Memory>& pane, std::size_t index) const;

      // Copy mode on a block's output: from its first character, or every line of it selected.
      void selectBlockOutput(const Pane<Memory>& pane, std::size_t index, bool lines);

      // A block's whole output to the clipboard, as the runtime reads it.
      void copyBlockOutput(const Pane<Memory>& pane, std::size_t index);

      // The row the shell's live prompt starts on, from the top of the scrollback, while the pane
      // shows its live end.
      [[nodiscard]] static std::optional<std::uint32_t> livePromptRow(const Pane<Memory>& pane);

      LineEntry& lineEntry(std::uint64_t pane_id);

      // The commands people typed, most recent first and each once, for the editor's suggestions.
      void requestPromptHistory();

      static_assert(runtime::config::prompt_action_names.size() == static_cast<std::size_t>(prompt::Action::insert_mode) + 1);

      // The action the user bound to this key in the editor's current mode, if any.
      std::optional<prompt::Action> boundAction(const prompt::KeyPress& key, const prompt::Editor& editor) const;

      // Sends what the editor decided: a command to run, a line for the running program, or raw
      // bytes the shell reads as keys. Commands are validated like a pasted history entry.
      void deliverPrompt(std::uint64_t pane_id, prompt::Outcome outcome, const prompt::Line& line);

      // Tab: the spec's literal choices at once, and the runtime's files when the spec, or a
      // command without one, expects a path there.
      void beginCompletion(std::uint64_t pane_id, prompt::Line& line, shell::Syntax syntax);

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

        std::size_t operator()(std::string_view text) const noexcept;
      };

      struct CommandChecks {
        std::uint32_t commands = 0;
        std::string directory;
        std::unordered_map<std::string, CommandPresence, StringHash, std::equal_to<>> words;
        // Every command that starts with a prefix, from an answer that listed them all: a longer
        // word typed under it is found or missing at once, without asking again.
        std::unordered_map<std::string, std::vector<std::string>, StringHash, std::equal_to<>> listed;
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
      CommandChecks& commandChecks(const Pane<Memory>& pane);

      // The first command `line` runs, as the editor colours it.
      void learnCommand(std::uint64_t pane_id, std::string_view line, shell::Dialect dialect);

      // Whether the runtime has a spec for `command` in this pane, asking it the first time: once
      // per command until the shell's next command, with the digest of the spec already held.
      SpecState specState(std::uint64_t pane_id, std::string_view command);

      // Keeps every command an answer listed under the word it was asked for, while what the pane
      // knows of its commands is still the one it asked from.
      void listCommands(std::uint64_t pane_id, std::string_view prefix, std::span<const CompletionWord> words);

      // A prompt request the runtime failed, or that a lost connection will never answer, settles
      // as one that found nothing: its word stops waiting, its spec is unavailable and its menu
      // stops expecting it. None of them is an error the user should read.
      std::optional<Change> failPromptRequest(std::uint64_t request_id);

      void failPromptRequests() noexcept;

      Change settleCommand(typename std::unordered_map<std::uint64_t, CommandRequest>::iterator request, CommandPresence presence);

      prompt::Specs prompt_specs_;
      // The suggestions read the whole history on every refresh: commands run since it loaded
      // replace the oldest instead of growing it for as long as the client lives.
      static constexpr std::uint16_t prompt_history_limit = 1000;
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
      std::unordered_map<std::uint64_t, LineEntry> lines_;
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
      tbc::view<Memory&, tbc::lt::a> memory_;
      tbc::view<RuntimeTransport&, tbc::lt::a> transport_;
      tbc::view<HostEffects&, tbc::lt::a> effects_;
      tbc::view<MonotonicNow, tbc::lt::static_storage> now_;
      // A session built without effects points `effects_` here.
      DiscardHostEffects discard_effects_;
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
      std::uint64_t chrome_revision_ = 0;
      tbc::view<features::history::State, tbc::lt::a> history_;
      tbc::view<features::peek::State, tbc::lt::a> peek_;
      features::paths::State paths_;
      features::palette::State palette_;
      tbc::view<Vector<Byte, Memory>, tbc::lt::a> decode_;
      tbc::view<String<Memory>, tbc::lt::a> clipboard_;
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
