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
import telar.gui.features.monitor;
import telar.gui.features.explorer;
import telar.gui.features.nvim;
import telar.gui.foundation.system;
import :client_view_state;
import :sidebar;
import telar.gui.features.palette;
import telar.gui.features.status_bar;
import telar.client;
import telar.config.client;
import telar.config.runtime;
import telar.gui.foundation.terminal;
import telar.base.text;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.graphics;
import telar.wire.history;
import telar.wire.layout;
import telar.wire.monitor;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.shell.syntax;
import telar.base.ds;

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
      // The monitor's answer, or what the runtime refused of it.
      monitor,
      // An editor pane shows another frame, or asks something else of the person.
      editor,
      // The runtime answered about its files, or ended a plan of the explorer.
      explorer,
    };

    // The clock a session reads, monotonic and in nanoseconds.
    using MonotonicNow = std::uint64_t (*)() noexcept;

    // The panes a session holds, each boxed so a pane stays put while the list grows.
    using Panes = ds::Vec<ds::Box<Pane<Memory>, Memory>, Memory>;

    // The tabs a session holds, boxed as its panes are.
    using Tabs = ds::Vec<ds::Box<Tab<Memory>, Memory>, Memory>;

    // Pane `pane_id` among `panes`. It borrows the panes alone, so a use case keeps it while it
    // changes another of the session's fields.
    [[nodiscard]] const Pane<Memory>* findPane(const Panes& panes, std::uint64_t pane_id) noexcept;

    // The same pane, to change it.
    [[nodiscard]] Pane<Memory>* findPaneMut(Panes& panes, std::uint64_t pane_id) noexcept;

    // The tab at `active` among `tabs`, once its record arrived. It borrows the tabs alone, as
    // findPane borrows the panes.
    [[nodiscard]] tbc::val_a<const Tab<Memory>*> activeTab(tbc::ref_a<Tabs> tabs, ds::Option<TabLocation> active) noexcept;

    // The same tab, to change it.
    [[nodiscard]] tbc::val_a<Tab<Memory>*> activeTabMut(tbc::mut_a<Tabs> tabs, ds::Option<TabLocation> active) noexcept;

    // The pane the tab at `active` focuses, among `panes`, which it borrows alone.
    [[nodiscard]] tbc::val_a<const Pane<Memory>*> focusedPane(tbc::ref_a<Panes> panes, const Tabs& tabs, ds::Option<TabLocation> active) noexcept;

    // A command block of a pane: the pane's id and the block's index among its blocks.
    struct BlockAt {
      std::uint64_t pane_id = 0;
      std::size_t index = 0;
    };

    // An inline document of a pane: the pane's id and the document's.
    struct InlineDocumentAt {
      std::uint64_t pane_id = 0;
      std::uint64_t id = 0;
    };

    // The way a step through a pane's blocks goes.
    enum class BlockStep : std::int8_t {
      up = -1,
      down = 1,
    };

    class Session {
      // The use cases of application::<feature> reach the members below through it.
      friend struct Access;

    public:
      static constexpr std::size_t decode_capacity = std::size_t{2} * 1024 * 1024;
      static constexpr std::size_t maximum_tabs = features::workbench::maximum_tabs;
      static constexpr std::size_t maximum_workspace_tabs = max_workspace_tabs;
      static constexpr std::size_t maximum_panes = maximum_tabs * PaneLayout::maximum_panes;
      static constexpr std::size_t maximum_pending = 256;
      static constexpr std::size_t maximum_retained_layout_nodes = max_retained_layout_nodes;
      static constexpr std::size_t input_chunk_size = 65536;
      // A viewport past any bottom: the runtime follows the output.
      static constexpr std::uint32_t follow_output = std::numeric_limits<std::uint32_t>::max();
      static constexpr std::uint16_t default_sidebar_columns = SidebarColumns::minimum_width;
      static constexpr std::size_t maximum_launch_arguments = max_launch_arguments;

      // The session keeps the allocator and the transport, region `a`, which also holds what its replies and
      // requests view of the session's own panes, workspaces and responses.
      Session(tbc::mut_a<Memory> allocator, tbc::mut_a<RuntimeTransport> transport, tbc::val_static<MonotonicNow> now = &system::AwakeClock::nowNanoseconds);

      // The session also keeps `effects`, region `a`.
      Session(tbc::mut_a<Memory> allocator, tbc::mut_a<RuntimeTransport> transport, tbc::mut_a<HostEffects> effects, tbc::val_static<MonotonicNow> now = &system::AwakeClock::nowNanoseconds);

      Session(const Session&) = delete;
      Session& operator=(const Session&) = delete;
      Session(Session&&) = delete;
      Session& operator=(Session&&) = delete;
      ~Session() = default;

      // The directory and arguments a new pane launches with, beside the strings the arguments view,
      // so it stays where it is made.
      class LaunchDefaults {
      public:
        explicit LaunchDefaults(tbc::mut_a<Memory> allocator);

        LaunchDefaults(const LaunchDefaults&) = delete;
        LaunchDefaults& operator=(const LaunchDefaults&) = delete;
        LaunchDefaults(LaunchDefaults&&) = delete;
        LaunchDefaults& operator=(LaunchDefaults&&) = delete;
        ~LaunchDefaults() = default;

        // The directory, else `/`, and the arguments, else a shell.
        [[nodiscard]] Launch launch() const noexcept;

        void set(const Launch& launch);

        void setDirectory(std::string_view directory);

        void setArguments(std::span<const std::string_view> arguments);

      private:
        void storeArguments(std::span<const std::string_view> arguments);

        tbc::val_a<Memory*> memory_;
        tbc::val_a<ds::String<Memory>> cwd_;
        tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> storage_;
        // The arguments view the strings stored beside them; the protocol allows at most 64.
        tbc::val_self<ds::Array<std::string_view, maximum_launch_arguments>> arguments_{};
        std::size_t count_ = 0;
      };

      void setLaunch(const Launch& launch);

      void setLaunchDirectory(std::string_view directory);

      void setLaunchArguments(std::span<const std::string_view> arguments);

      void setRestoreLayout(bool enabled) noexcept;

      // `dialect`: the schema the runtime answered the handshake with. The session asks an older
      // runtime only for what its dialect has.
      void connected(std::uint64_t identity, handshake::Dialect dialect = handshake::current_dialect);

      [[nodiscard]] bool requestsPending() const noexcept;

      [[nodiscard]] bool presented() const noexcept;

      void setPresented(bool presented);

      bool settlePresentation();

      void disconnected() noexcept;

      Change consume(std::span<const Byte> payload);

      Change consume(std::span<const Byte> payload, ClientCommandHandler& handler);

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

      // Whether the runtime hears the client's theme, editor colors included.
      [[nodiscard]] bool readsTheme() const noexcept;

      [[nodiscard]] bool monitors() const noexcept;

      // Whether the runtime answers the explorer about its files.
      [[nodiscard]] bool explores() const noexcept;

      // Whether the runtime the session is connected to understands `tag`.
      [[nodiscard]] bool speaks(ClientTag tag) const noexcept;

      // Whether the runtime speaks `dialect` or a newer one, for what a dialect changed in a
      // request every runtime knows.
      [[nodiscard]] bool speaks(handshake::Dialect dialect) const noexcept;

      // Asks for the rows from stable row `first` to `last` the pane holds neither on its screen
      // nor in its cache, a request at a time while requests are free.
      void requestRows(std::uint64_t pane_id, std::uint64_t first, std::uint64_t last);

      // The rows the scrollback dropped from its top since the pane's view last asked: the view
      // moves up by as many to keep showing the same rows.
      [[nodiscard]] std::uint64_t takeDroppedRows(std::uint64_t pane_id) noexcept;

      // ---- folded commands ------------------------------------------------------------------------

      // The stable number of a block's first row, which names it while rows above it are dropped.
      [[nodiscard]] static std::uint64_t blockKey(const Pane<Memory>& pane, std::size_t index) noexcept;

      [[nodiscard]] bool folded(BlockAt block) const noexcept;

      // Folds the output of block `index`, or unfolds it. Only a runtime that sends rows apart from
      // the screen can show what follows a fold.
      void fold(BlockAt block, bool fold);

      // Folds every block but a running one, or unfolds them all.
      void foldAll(std::uint64_t pane_id, bool fold);

      // The rows of block `index`'s output, from under its prompt to above the next prompt, or to
      // the live prompt or the scrollback's end for the last; empty when it printed nothing.
      [[nodiscard]] static std::pair<std::uint32_t, std::uint32_t> blockRows(const Pane<Memory>& pane, std::size_t index) noexcept;

      // The row block `index`'s separator is drawn on: the command's first, where telar's prompt
      // leaves it, with the rows of a command that runs on past it shown under it.
      [[nodiscard]] static std::uint64_t separatorRow(const Pane<Memory>& pane, std::size_t index) noexcept;

      // ---- command blocks, selected from the editor -------------------------------------------

      [[nodiscard]] ds::Option<std::size_t> selectedBlock(std::uint64_t pane_id) const noexcept;

      // Selects the block at `index`, or none: the pane's live end. The view moves only when the
      // block's separator is out of it, to the pane's top. `by_pointer` for a click: the keys that
      // type still go to the editor.
      void selectBlock(std::uint64_t pane_id, ds::Option<std::size_t> index, bool by_pointer = false);

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

      [[nodiscard]] const Pane<Memory>* findPane(std::uint64_t pane_id) const noexcept;

      // The same pane, to change it.
      [[nodiscard]] Pane<Memory>* findPaneMut(std::uint64_t pane_id) noexcept;

      [[nodiscard]] const Tab<Memory>* activeTab() const noexcept;

      [[nodiscard]] Tab<Memory>* activeTabMut() noexcept;

      [[nodiscard]] const Pane<Memory>* focusedPane() const noexcept;

      [[nodiscard]] Pane<Memory>* focusedPaneMut() noexcept;

      [[nodiscard]] const ds::Vec<Workspace<Memory>, Memory>& workspaces() const noexcept;

      [[nodiscard]] const ds::Vec<Agent<Memory>, Memory>& agents() const noexcept;

      [[nodiscard]] std::uint64_t agentRevision() const noexcept;

      [[nodiscard]] std::span<const ListedPane> paneList() const noexcept;

      [[nodiscard]] std::uint64_t paneListRevision() const noexcept;

      // Counts the changes to the facts of the listed panes: their commands, directories and
      // repositories, which the list's revision does not count.
      [[nodiscard]] std::uint64_t paneFactsRevision() const noexcept;

      [[nodiscard]] std::string_view clipboard() const noexcept;

      // Changes with what a pane's header and its tab show: title, directory, program, progress,
      // git, the shell's host and link, and whether a tab's panes are loaded. ViewVersion leaves
      // these out on purpose: they never move a link under the pointer.
      [[nodiscard]] std::uint64_t chromeRevision() const noexcept;

      [[nodiscard]] std::string_view error() const noexcept;

      void dismissDiagnostic() noexcept;

      [[nodiscard]] bool ready() const noexcept;

      // The view measured an inline document in `rows` rows of its own.
      bool measureInline(InlineDocumentAt document, std::uint32_t rows);

      [[nodiscard]] std::uint64_t changedPane() const noexcept;

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
        ds::Option<std::uint64_t> fallback_workspace = ds::none;
      };

      struct MachineBookmark {
        TabLocation location;
        std::uint64_t pane_id = 0;
        ds::Option<std::uint64_t> fallback_workspace;
      };

    public:
      // The connection with the runtime and the requests it is yet to answer, a field of its own: a
      // use case asks and sends while it holds a feature's state, as Rust borrows one field at a time.
      class Link {
      public:
        explicit Link(tbc::mut_a<RuntimeTransport> runtime_transport) noexcept;

        [[nodiscard]] std::uint64_t nextRequest() noexcept;

        // A request of `kind` the runtime will answer, tracked under a new id until it does.
        std::uint64_t pending(RequestKind kind, std::uint64_t pane_id = 0, ClientLayoutAxis axis = ClientLayoutAxis::horizontal);

        ds::Option<Pending> complete(std::uint64_t request_id) noexcept;

        // Completes `request_id` when it is a pending request of `kind`.
        bool completeRequest(RequestKind kind, std::uint64_t request_id) noexcept;

        // The requests the runtime is yet to answer.
        [[nodiscard]] std::span<const Pending> requests() const noexcept;

        // What is tracked of the request `pending` registered last, for its reply to read.
        [[nodiscard]] Pending& lastPending() noexcept;

        // Forgets every request, as a new connection answers none of them.
        void forgetRequests() noexcept;

        // Encodes `message` into the storage the transport lends.
        template <typename Message>
        std::span<const Byte> encode(const Message& message);

        template <typename Message>
        void send(const Message& message);

        // Sends `request`, whose id its maker chose; false when the transport's queue is full and
        // the request did not leave. A full queue is no failure: the caller asks again later, and
        // records its wait only for a request that left.
        template <typename Request>
        [[nodiscard]] bool offer(const Request& request);

        // offer under a new id, which it returns: nothing when the request did not leave.
        template <typename Request>
        [[nodiscard]] ds::Option<std::uint64_t> ask(Request request);

        // Sends a limit report unless the transport is too busy for one; false when it dropped it.
        bool report(const ReportLimit& report);

        // Sends `request` under a new pending id of `kind`, once `fill` recorded in the pending entry
        // what the reply will need; a request the transport refuses leaves nothing pending.
        template <typename Request, typename Fill>
        void sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id, Fill&& fill);

        template <typename Request>
        void sendRegistered(RequestKind kind, Request request, std::uint64_t pane_id = 0);

        // Asks the runtime to open a pane or a workspace, tracked as `kind` until it does, with the
        // tab it opens in and the workspace to fall back to.
        template <typename Request>
          requires(std::same_as<Request, OpenPane> || std::same_as<Request, CreateWorkspace>)
        void sendOpeningRequest(RequestKind kind, Request request, TabLocation location = TabLocation(), ds::Option<std::uint64_t> fallback_workspace = ds::none);

        // Asks the runtime to describe a tab or a workspace, which it answers with a snapshot.
        template <typename Request>
          requires(std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot>)
        void sendSnapshotRequest(Request request);

        // Sends a request to create, rename, move or close a tab, tracked until the runtime answers.
        template <typename Request>
        void sendTabOperation(RequestKind kind, Request request);

        // Public beside a private counter, so that a use case borrows the transport alone.
        tbc::mut_a<RuntimeTransport> transport; // NOLINT(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)

      private:
        std::uint64_t request_id_ = 0;
        ds::Array<Pending, maximum_pending> pending_;
        std::size_t pending_count_ = 0;
      };

    private:
      Pane<Memory>& allocateSplitPane(const Pending& request, const PaneOpened& message);

      Change adoptSplit(const Pending& request, const PaneOpened& message);

      template <typename Value>
      static void reserveAppend(ds::Vec<Value, Memory>& values, std::size_t maximum);

      [[nodiscard]] const Tab<Memory>* findTab(TabLocation location) const noexcept;

      [[nodiscard]] Tab<Memory>* findTabMut(TabLocation location) noexcept;

      Tab<Memory>& ensureTab(TabLocation location);

      Pane<Memory>& ensurePane(std::uint64_t pane_id, TabLocation location);

      void openDefault();

      [[nodiscard]] ds::Option<MachineBookmark> machineBookmark() const noexcept;

      bool recoverMissingWorkspacePane(const Pending& request, const RequestFailed& failure);

      // Undoes what `request`, which failed, had started. A change it returns settles the failure;
      // none leaves the failure to show as the session's error.
      ds::Option<Change> failPending(const Pending& request, const RequestFailed& message);

      void handoffPane(std::uint64_t pane_id, ds::Option<std::uint64_t> fallback_workspace);

      void handoffWorkspace(PaneTarget target, ds::Option<std::uint64_t> fallback_workspace);

      void releaseWorkspacePresentation() noexcept;

      void restoreMachinePresentation();

      void openRestoredWorkspace(TabLocation location);

      void confirmAttachment(Pane<Memory>& pane);

      void synchronizeAttachments();

      // Detaches pane `pane_id` from the runtime, closing copy mode when it reads that pane, and
      // leaving its editor, if it is one, to take the next frame whole. Static, with the fields
      // it changes, so a loop over the panes may call it.
      static void detachPane(features::terminal::copy_mode::State& copy_mode, features::nvim::State& nvim, Link& link, std::uint64_t pane_id);

    public:
      // Gives pane `pane_id` `size`, telling the runtime through `link` while it is attached. Static,
      // with the fields it changes, so the layout may call it while it holds a tab.
      static void resizePane(Panes& panes, Link& link, ViewVersion& view_version, std::uint64_t pane_id, TerminalSize size);

    private:
      Change apply(const PaneMatches& message);

      Change apply(const PaneFrame& message);

      // The rows the folded blocks hide, from their stable numbers; folds whose blocks are gone
      // are forgotten.
      void refreshFolds(Pane<Memory>& pane);

      template <typename Message>
      Change dispatchMessage(std::span<const Byte> payload, DecodeStorage& storage, ClientCommandHandler& handler);

      using Dispatch = Change (Session::*)(std::span<const Byte> payload, DecodeStorage& storage, ClientCommandHandler& handler);
      using DispatchTable = ds::Array<Dispatch, std::numeric_limits<Byte>::max() + 1>;
      // What applies each of the runtime's messages, by its tag.
      [[nodiscard]] static consteval DispatchTable routed();

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

      Change apply(const PaneFacts& message);

      Change apply(const HistoryResults& message);

      Change apply(const HistoryOutput& message);

      Change apply(const HistoryPruned& message);

      Change apply(const CompletionWords& message);

      Change apply(const PathResults& message);

      Change apply(const CommandSuggestion& message);

      Change apply(const SystemMetrics& message);
      Change apply(const MonitorSnapshot& message);
      Change apply(const DirectoryContents& message);
      Change apply(const DirectorySizes& message);
      Change apply(const RepositoryChanges& message);
      Change apply(const FileInspection& message);
      Change apply(const FilesChanged& message);
      Change apply(const ChangesCommitted& message);
      Change apply(const HomeLocated& message);
      Change apply(const FileChunk& message);
      Change apply(const FileWritten& message);
      Change apply(const FileWriteEnded& message);
      Change apply(const FileTouches& message);

      Change apply(const PlacesKept& message);
      Change apply(const ExplorerKept& message);

      Change apply(const PaneKindNotice& message);
      Change apply(const NvimGrid& message);
      Change apply(const NvimFrame& message);
      Change apply(const NvimCmdline& message);
      Change apply(const NvimPopupMenu& message);
      Change apply(const NvimMessageList& message);
      Change apply(const NvimTabLine& message);
      Change apply(const NvimPrompt& message);
      Change apply(const NvimNavigated& message);
      Change apply(const NvimPick& message);
      Change apply(const NvimOpenFiles& message);
      Change apply(const NvimExplore& message);
      Change apply(const NvimLink& message);
      Change apply(const TextResults& message);

      Change apply(const ProxyStatus& message);

      Change apply(const RequestFailed& message);

      Change apply(const EditorOpened& message);

      Change apply(const RequestCompleted& message);

      Change apply(const PaneText& message);

      Change apply(const ResyncRequired& message);

      Change apply(const Notification& message);

      Change apply(const AgentSoundNotification& message);

      Change apply([[maybe_unused]] const RuntimeStopping& message);

      Change apply(const ClientCommand& message, ClientCommandHandler& handler);

      Change executeCommand(const ClientCommand& message, tbc::mut_a<CompleteClientCommand> reply, ClientCommandHandler& handler);

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

      // The fields below are public beside private state on purpose: the use cases borrow them one by
      // one, as Rust borrows a struct's fields, where an accessor would lend the whole session.
      // NOLINTBEGIN(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)
    public:
      // The configuration the session runs with, a field the use cases read beside a feature's state.
      Configuration configuration;

    private:
    public:
      // What a view of the session has to redraw: a use case that moves a pane's view bumps it.
      ViewVersion view_version;

    private:
      // The keys of the command blocks, ahead of the editor. From the normal mode: Ctrl-U and
      // Ctrl-D, or [[ and ]], step through the blocks, [f and ]f through the failed ones, Ctrl-O and
      // Ctrl-I back and forth through the jumps. On a selected block: j and k move the view a row,
      // gg to the top and G to the live end; zt, zz and zb put the block at the view's top, middle
      // or bottom; za, zc and zo fold its output, zM and zR every block's; / searches its output;
      // v and V select its output, Y copies it and yc its command; Esc, q, i, a, I, A and any other
      // key go back to the prompt.
      ds::Option<features::prompt::Outcome> blockKey(std::uint64_t pane_id, const features::prompt::KeyPress& key);

      // The block selected in `line` while it is one of `pane`'s.
      [[nodiscard]] static ds::Option<std::size_t> blockSelection(const Pane<Memory>& pane, const features::prompt::PaneLine& line) noexcept;

      // Selects block `index` of `pane`, or none, as a jump.
      void jumpToBlock(std::uint64_t pane_id, ds::Option<std::size_t> index);

      // Selects the block above (`direction` -1) or below (1) the selected one. With none selected,
      // going up selects the last block.
      void stepBlock(std::uint64_t pane_id, BlockStep direction);

      // Selects the next failed block above or below the selected one, or from the live end.
      void stepFailedBlock(std::uint64_t pane_id, BlockStep direction);

      // Ctrl-U, Ctrl-D, Ctrl-O and Ctrl-I; false for any other `character`.
      bool controlBlockKey(std::uint64_t pane_id, char32_t character);

      // The chord `pending` began, yc, gg or z and a key, ended by `character` on block `index`;
      // false when `pending` begins none of them.
      bool blockChord(char pending, BlockAt block, char32_t character);

      // The z chord ended by `character` on block `index`; false when `character` ends none.
      bool foldChord(BlockAt block, char32_t character);

      // A key while the pointer holds a block selected outside vim's normal mode: Escape leaves it,
      // the arrows step through the blocks, and any other key leaves it for the editor.
      ds::Option<features::prompt::Outcome> pointerBlockKey(std::uint64_t pane_id, const features::prompt::KeyPress& key);

      // The selected block of `pane`, by its stable key, before its blocks change; `restoreBlock`
      // selects it again at its new index, or nothing when it is gone.
      [[nodiscard]] ds::Option<std::uint64_t> selectedBlockKey(const Pane<Memory>& pane) const noexcept;
      void restoreBlock(const Pane<Memory>& pane, ds::Option<std::uint64_t> key);

      // A key on block `index` outside a chord; false when it is none of block mode's.
      bool blockCommand(BlockAt block, char32_t character);

      // The shown row at the view's top: as its view says, or as the runtime's view puts it.
      [[nodiscard]] static std::uint64_t shownTop(const Pane<Memory>& pane) noexcept;

      // Scrolls the pane so that shown row `display`, folds counted, is the view's top.
      void scrollToShownRow(const Pane<Memory>& pane, std::uint64_t display);

      // The view's top, by stable row, as a jump remembers it.
      [[nodiscard]] static std::uint64_t jumpRow(const Pane<Memory>& pane) noexcept;

      // Remembers the view's top before a jump, dropping the jumps Ctrl-O had gone back past.
      static void recordJump(const Pane<Memory>& pane, features::prompt::PaneLine& line);

      // Back to where the last jump left from, or forward again; the view's top goes there.
      // The row of `pane` the line's jump list moves to, back or forth, among the rows it shows.
      [[nodiscard]] static ds::Option<std::uint32_t> jumpTarget(const Pane<Memory>& pane, features::prompt::PaneLine& line, bool back);

      // Copy mode on a block's output, at its first row, with the scrollback search asked for and
      // confined to that output.
      void searchBlockOutput(Pane<Memory>& pane, std::size_t index);

      // The rows of a block's output: from under its command to above the next block's prompt, or
      // the live prompt's for the last one.
      [[nodiscard]] static ds::Option<std::pair<std::uint32_t, std::uint32_t>> blockOutput(const Pane<Memory>& pane, std::size_t index) noexcept;

      // Copy mode on a block's output: from its first character, or every line of it selected.
      void selectBlockOutput(const Pane<Memory>& pane, std::size_t index, bool lines);

      // A block's whole output to the clipboard, as the runtime reads it.
      void copyBlockOutput(const Pane<Memory>& pane, std::size_t index);

      // Copies block `index`'s command whole, as the rows it was typed on hold it: the block's
      // own text is its first line, cut short.
      void copyBlockCommand(const Pane<Memory>& pane, std::size_t index);

      // The row the shell's live prompt starts on, from the top of the scrollback, while the pane
      // shows its live end.
      [[nodiscard]] static ds::Option<std::uint32_t> livePromptRow(const Pane<Memory>& pane);

      bool chrome_changed_ = false;
      bool clipboard_written_ = false;
      bool block_changed_ = false;

    public:
      // The features' states, which their use cases in application::<feature> reach directly, as Rust
      // borrows a struct's fields: an accessor would lend the whole session.
      tbc::val_a<features::prompt::State> prompt;
      tbc::val_a<features::prompt::Lines> prompt_lines;
      tbc::val_a<features::terminal::copy_mode::State> copy_mode;
      features::terminal::links::State links;
      features::status_bar::State status_bar;

    private:
      ProxyStatus proxy_{};

    public:
      // Where the session and its features allocate; a reference, so lending it lends no field.
      tbc::mut_a<Memory> memory;

    private:
    public:
      tbc::val_a<Link> link;

    private:
      tbc::mut_a<HostEffects> effects_;
      tbc::val_static<MonotonicNow> now_;
      // A session built without effects points `effects_` here.
      DiscardHostEffects discard_effects_;

    public:
      features::terminal::graphics::State graphics;

    private:
      // The bytes every pane's images count against, shared by the panes' stores; declared before
      // the panes, which give theirs back as they go.
      features::terminal::graphics::GraphicsBudget graphics_budget_;

    public:
    private:
    public:
      // The panes and tabs the runtime reported, which the use cases search as fields of their own.
      tbc::val_a<Panes> panes;
      tbc::val_a<Tabs> tabs;

    private:
    public:
      // The workspaces and worktrees the runtime lists, a field the use cases walk while they send.
      tbc::val_a<WorkspaceReplica<Memory>> workspace_list;

    private:
    public:
      // The agents the runtime reports, a field the use cases read while they send.
      tbc::val_a<AgentReplica<Memory>> agent_list;

    private:
      tbc::val_a<PaneListReplica<Memory>> pane_list_;
      AgentAcknowledgement agent_acknowledgement_;

    public:
      features::notifications::State notifications;

    private:
      std::uint64_t chrome_revision_ = 0;

    public:
      tbc::val_a<features::history::State> history;
      tbc::val_a<features::peek::State> peek;
      tbc::val_a<features::monitor::State> monitor;
      // The files of the machine, as its runtime answered the explorer.
      tbc::val_a<features::explorer::State> explorer;
      // The editor panes: what each Neovim shows, as the runtime last sent it.
      tbc::val_a<features::nvim::State> nvim;
      features::paths::State paths;
      features::palette::State palette;

    private:
      tbc::val_a<ds::Vec<Byte, Memory>> decode_;
      tbc::val_a<ds::String<Memory>> clipboard_;
      // The start of a command whose rows a copy reads: what the rows hold before it is a
      // prompt's, which the copy leaves out. Empty when no such copy is on its way.
      tbc::val_a<ds::String<Memory>> command_copy_;
      std::uint64_t command_copy_pane_ = 0;
      tbc::val_a<ds::String<Memory>> error_;
      tbc::val_a<ds::String<Memory>> command_response_;

    public:
      // What a pane launches with when its request names nothing else, a field the use cases read
      // while they send through the link.
      tbc::val_a<LaunchDefaults> launch_defaults;

    private:
    public:
      // The tab the session shows, by location, whether or not its record arrived.
      ds::Option<TabLocation> active_tab;

    private:
    public:
      features::workbench::State workbench;

    private:
      ds::Option<TabLocation> deferred_tab_;
      ds::Option<MachineBookmark> left_machine_;
      std::uint64_t attachment_generation_ = 0;
      std::uint64_t changed_pane_ = 0;
      bool ready_ = false;
      // The dialect of the runtime the session is connected to; none before the first connection.
      ds::Option<handshake::Dialect> dialect_;
      bool presented_ = true;
      bool leave_pending_ = false;
      bool initial_open_pending_ = false;
      bool restore_layout_ = true;
      bool workspace_list_collapsed_ = false;
      std::uint16_t display_fps_ = Configuration::default_fps;
      std::uint16_t sidebar_columns_ = default_sidebar_columns;
      std::uint16_t host_columns_ = default_terminal_size.cols;
      // NOLINTEND(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)
    };

  }
}
