module;
#include "tbc/annotations.hpp"

export module telar.gui.application:session;

import std;
import telar.tbc;

import :host_effects;
import :workspace_replica;
import telar.gui.foundation.core;
import telar.gui.features.terminal.graphics;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.gui.features.terminal.copy_mode;
import telar.gui.features.workbench;
import telar.gui.features.notifications;
import telar.gui.foundation.model;
import telar.gui.features.terminal.links;
import telar.gui.features.paths;
import telar.gui.features.peek;
import telar.gui.foundation.system;
import :client_view_state;
import :sidebar;
import telar.gui.features.palette;
import telar.gui.features.status_bar;
import telar.config.client;
import telar.config.runtime;
import telar.gui.foundation.terminal;
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
import telar.base.memory.allocators;
import telar.shell.syntax;

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

    // The clock a session reads, monotonic and in nanoseconds.
    using MonotonicNow = std::uint64_t (*)() noexcept;

    class Session {
      // The use cases of application::<feature> reach the members below through it.
      friend struct Access;

    public:
      static constexpr std::size_t decode_capacity = std::size_t{2} * 1024 * 1024;
      static constexpr std::size_t maximum_tabs = features::workbench::maximum_tabs;
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

      void input(std::uint64_t pane_id, std::string_view bytes, PaneInputSource source = PaneInputSource::keyboard);

      // Runs a command at the pane's prompt. A runtime that takes commands types it there itself and
      // keeps this text for the command's history; an older one (schema cqp00002) gets it pasted,
      // then Enter, and reads the command back from the screen.
      void runCommand(std::uint64_t pane_id, std::string_view text);

      // Typing returns a scrolled pane to its live end, where the output follows.
      void followLiveEnd(Pane<Memory>& pane);

      void notePaneInput(const Pane<Memory>& pane);

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

      // Whether a block was selected or left, or copy mode began on one, since the last call.
      [[nodiscard]] bool takeBlockChange() noexcept;

      // Whether text was written to the clipboard since the last call, as copying a command does.
      [[nodiscard]] bool takeClipboardWrite() noexcept;

      // Whether a pane's header changed with its shell's state since the last call.
      [[nodiscard]] bool takeChromeChange() noexcept;

      // Scrolls the pane so `row`, counted from the top of its scrollback, is the first shown.
      void scrollToRow(std::uint64_t pane_id, std::uint32_t row);

      void paste(std::uint64_t pane_id, std::string_view bytes);

      // A paste straight to the terminal, framed when the program asked for bracketed paste.
      void pasteBytes(std::uint64_t pane_id, std::string_view bytes);

      void resize(std::uint64_t pane_id, TerminalSize size);

      void presented(std::uint64_t pane_id, std::uint64_t frame_id);

      void scroll(PaneScrollDelta delta);

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

      // Changes with what a pane's header and its tab show: title, directory, program, progress,
      // git, the shell's host and link, and whether a tab's panes are loaded. ViewVersion leaves
      // these out on purpose: they never move a link under the pointer.
      [[nodiscard]] std::uint64_t chromeRevision() const noexcept;

      [[nodiscard]] std::string_view error() const noexcept;

      void dismissDiagnostic() noexcept;

      [[nodiscard]] bool ready() const noexcept;

      // The view measured an inline document in `rows` rows of its own.
      bool measureInline(std::uint64_t pane_id, std::uint64_t id, std::uint32_t rows);

      [[nodiscard]] std::uint64_t changedPane() const noexcept;

      [[nodiscard]] const Configuration& configuration() const noexcept;

      [[nodiscard]] ClientViewState clientViewState() const noexcept;

      [[nodiscard]] ViewVersion viewVersion() const noexcept;

      void invalidateView() noexcept;

      void setSidebarVisible(bool visible);

      void setSidebarWidth(float width);

      void setHostColumns(std::uint16_t columns) noexcept;

      [[nodiscard]] bool workspaceListCollapsed() const noexcept;

      void setWorkspaceListCollapsed(bool collapsed);

      [[nodiscard]] const ProxyStatus& proxyStatus() const noexcept;

    private:
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

      template <typename Request>
        requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
      void sendOpeningRequest(RequestKind kind, Request request, TabLocation location = TabLocation(), std::optional<std::uint64_t> fallback_workspace = std::nullopt);

      template <typename Request>
        requires(std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot>)
      void sendSnapshotRequest(Request request);

      bool completeRequest(RequestKind kind, std::uint64_t request_id) noexcept;

      Pane<Memory>& allocateSplitPane(const Pending& request, const PaneOpened& message);

      Change adoptSplit(const Pending& request, const PaneOpened& message);

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

      std::uint64_t nextRequest() noexcept;

      std::uint64_t pending(RequestKind kind, std::uint64_t pane_id = 0, ClientLayoutAxis axis = ClientLayoutAxis::horizontal);

      std::optional<Pending> complete(std::uint64_t request_id) noexcept;

      [[nodiscard]] Tab<Memory>* findTab(TabLocation location) const noexcept;

      Tab<Memory>& ensureTab(TabLocation location);

      Pane<Memory>& ensurePane(std::uint64_t pane_id, TabLocation location);

      void openDefault();

      [[nodiscard]] std::optional<MachineBookmark> machineBookmark() const noexcept;

      bool recoverMissingWorkspacePane(const Pending& request, const RequestFailed& failure);

      void handoffPane(std::uint64_t pane_id, std::optional<std::uint64_t> fallback_workspace);

      void handoffWorkspace(PaneTarget target, std::optional<std::uint64_t> fallback_workspace);

      void releaseWorkspacePresentation() noexcept;

      void restoreMachinePresentation();

      void openRestoredWorkspace(TabLocation location);

      void confirmAttachment(Pane<Memory>& pane);

      [[nodiscard]] Launch defaultLaunch() const noexcept;

      void synchronizeAttachments();

      void prepareDetach(std::uint64_t pane_id);

      Change apply(const PaneMatches& message);

      Change apply(const PaneFrame& message);

      // The rows the folded blocks hide, from their stable numbers; folds whose blocks are gone
      // are forgotten.
      void refreshFolds(Pane<Memory>& pane);

      template <typename Message>
      Change dispatchMessage(std::span<const Byte> payload, DecodeStorage& storage, const ClientCommandHandler& handler);

      void recoverRuntime(std::string_view reason);

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

      Change apply(const RequestCompleted& message);

      Change apply(const PaneText& message);

      Change apply(const ResyncRequired& message);

      Change apply(const Notification& message);

      Change apply(const AgentSoundNotification& message);

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

      Change apply(const PaneFocusCommand& message);

      Configuration configuration_;
      ViewVersion view_version_;

      // The keys of the command blocks, ahead of the editor. From the normal mode: Ctrl-U and
      // Ctrl-D, or [[ and ]], step through the blocks, [f and ]f through the failed ones, Ctrl-O and
      // Ctrl-I back and forth through the jumps. On a selected block: j and k move the view a row,
      // gg to the top and G to the live end; zt, zz and zb put the block at the view's top, middle
      // or bottom; za, zc and zo fold its output, zM and zR every block's; / searches its output;
      // v and V select its output, Y copies it and yc its command; Esc, q, i, a, I, A and any other
      // key go back to the prompt.
      std::optional<features::prompt::Outcome> blockKey(std::uint64_t pane_id, features::prompt::PaneLine& line, const features::prompt::KeyPress& key);

      // The shown row at the view's top: as its view says, or as the runtime's view puts it.
      [[nodiscard]] static std::uint64_t shownTop(const Pane<Memory>& pane) noexcept;

      // Scrolls the pane so that shown row `display`, folds counted, is the view's top.
      void scrollToShownRow(const Pane<Memory>& pane, std::uint64_t display);

      // The view's top, by stable row, as a jump remembers it.
      [[nodiscard]] static std::uint64_t jumpRow(const Pane<Memory>& pane) noexcept;

      // Remembers the view's top before a jump, dropping the jumps Ctrl-O had gone back past.
      static void recordJump(const Pane<Memory>& pane, features::prompt::PaneLine& line);

      // Back to where the last jump left from, or forward again; the view's top goes there.
      void jumpBack(const Pane<Memory>& pane, features::prompt::PaneLine& line, bool back);

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

      bool chrome_changed_ = false;
      bool clipboard_written_ = false;
      bool block_changed_ = false;
      features::prompt::State prompt_;
      features::terminal::copy_mode::State copy_mode_;
      features::terminal::links::State links_;
      features::status_bar::State status_bar_;
      ProxyStatus proxy_{};
      tbc::view<Memory&, tbc::lt::a> memory_;
      tbc::view<RuntimeTransport&, tbc::lt::a> transport_;
      tbc::view<HostEffects&, tbc::lt::a> effects_;
      tbc::view<MonotonicNow, tbc::lt::static_storage> now_;
      // A session built without effects points `effects_` here.
      DiscardHostEffects discard_effects_;
      features::terminal::graphics::State graphics_;
      tbc::view<Vector<Owned<Pane<Memory>, Memory>, Memory>, tbc::lt::a> panes_;
      tbc::view<Vector<Owned<Tab<Memory>, Memory>, Memory>, tbc::lt::a> tabs_;
      tbc::view<WorkspaceReplica<Memory>, tbc::lt::a> workspaces_;
      tbc::view<AgentReplica<Memory>, tbc::lt::a> agents_;
      tbc::view<PaneListReplica<Memory>, tbc::lt::a> pane_list_;
      AgentAcknowledgement agent_acknowledgement_;
      features::notifications::State notifications_;
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
      features::workbench::State workbench_;
      std::optional<TabLocation> deferred_tab_;
      std::optional<MachineBookmark> left_machine_;
      std::uint64_t request_id_ = 0;
      std::uint64_t attachment_generation_ = 0;
      std::uint64_t changed_pane_ = 0;
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
