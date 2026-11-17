// What the use cases of application::<feature> reach of the state they compose. A partition the
// module does not export: only the module's own units import it, and ui cannot name Access.
module telar.gui.application:access;

import std;

import :session;
import telar.gui.features.palette;
import telar.gui.features.paths;
import telar.gui.features.history;
import telar.gui.features.notifications;
import telar.gui.features.prompt;
import telar.gui.features.status_bar;
import telar.gui.features.peek;
import telar.gui.features.terminal.copy_mode;
import telar.gui.features.terminal.graphics;
import telar.gui.features.terminal.links;
import telar.gui.features.workbench;

namespace telar::gui::application {

  // Session befriends it; each accessor hands out one member, so a use case reaches what it
  // works on and the members stay out of Session's public interface. Accessors are added with
  // the use cases that need them, and stay inline so a use case costs what the method it
  // replaces did.
  struct Access {
    // The kinds of the requests Session tracks until the runtime answers them, and what it tracks
    // of each.
    using RequestKind = Session::RequestKind;
    using Pending = Session::Pending;

    [[nodiscard]] static constexpr Configuration& configuration(Session& session) noexcept {
      return session.configuration_;
    }

    [[nodiscard]] static constexpr const Configuration& configuration(const Session& session) noexcept {
      return session.configuration_;
    }

    [[nodiscard]] static constexpr features::peek::State& peek(Session& session) noexcept {
      return session.peek_;
    }

    [[nodiscard]] static constexpr const features::peek::State& peek(const Session& session) noexcept {
      return session.peek_;
    }

    [[nodiscard]] static constexpr features::palette::State& palette(Session& session) noexcept {
      return session.palette_;
    }

    [[nodiscard]] static constexpr const features::palette::State& palette(const Session& session) noexcept {
      return session.palette_;
    }

    [[nodiscard]] static constexpr features::paths::State& paths(Session& session) noexcept {
      return session.paths_;
    }

    [[nodiscard]] static constexpr const features::paths::State& paths(const Session& session) noexcept {
      return session.paths_;
    }

    [[nodiscard]] static constexpr features::history::State& history(Session& session) noexcept {
      return session.history_;
    }

    [[nodiscard]] static constexpr const features::history::State& history(const Session& session) noexcept {
      return session.history_;
    }

    [[nodiscard]] static constexpr features::prompt::State& prompt(Session& session) noexcept {
      return session.prompt_;
    }

    [[nodiscard]] static constexpr const features::prompt::State& prompt(const Session& session) noexcept {
      return session.prompt_;
    }

    [[nodiscard]] static constexpr features::terminal::copy_mode::State& copyMode(Session& session) noexcept {
      return session.copy_mode_;
    }

    [[nodiscard]] static constexpr const features::terminal::copy_mode::State& copyMode(const Session& session) noexcept {
      return session.copy_mode_;
    }

    [[nodiscard]] static constexpr features::terminal::graphics::State& graphics(Session& session) noexcept {
      return session.graphics_;
    }

    [[nodiscard]] static constexpr const features::terminal::graphics::State& graphics(const Session& session) noexcept {
      return session.graphics_;
    }

    [[nodiscard]] static constexpr features::notifications::State& notifications(Session& session) noexcept {
      return session.notifications_;
    }

    [[nodiscard]] static constexpr const features::notifications::State& notifications(const Session& session) noexcept {
      return session.notifications_;
    }

    [[nodiscard]] static constexpr features::status_bar::State& statusBar(Session& session) noexcept {
      return session.status_bar_;
    }

    [[nodiscard]] static constexpr const features::status_bar::State& statusBar(const Session& session) noexcept {
      return session.status_bar_;
    }

    [[nodiscard]] static constexpr features::terminal::links::State& links(Session& session) noexcept {
      return session.links_;
    }

    // ---- what the session keeps for every feature -------------------------------------------

    // The refresh rate of the display the session's window shows on.
    [[nodiscard]] static constexpr std::uint16_t& displayFps(Session& session) noexcept {
      return session.display_fps_;
    }

    [[nodiscard]] static constexpr Memory& memory(Session& session) noexcept {
      return session.memory_;
    }

    [[nodiscard]] static constexpr String<Memory>& clipboard(Session& session) noexcept {
      return session.clipboard_;
    }

    // What a view of the session has to redraw: a use case that moves a pane's view bumps it.
    [[nodiscard]] static constexpr ViewVersion& viewVersion(Session& session) noexcept {
      return session.view_version_;
    }

    // The pane whose terminal changed since the last message, for its view to redraw.
    [[nodiscard]] static constexpr std::uint64_t& changedPane(Session& session) noexcept {
      return session.changed_pane_;
    }

    // The tab the session shows, by location, whether or not its record arrived.
    [[nodiscard]] static constexpr const std::optional<TabLocation>& activeTab(const Session& session) noexcept {
      return session.active_tab_;
    }

    // The agents the runtime reports and the panes it lists, which the session replicates.
    [[nodiscard]] static constexpr AgentReplica<Memory>& agents(Session& session) noexcept {
      return session.agents_;
    }

    [[nodiscard]] static constexpr PaneListReplica<Memory>& paneList(Session& session) noexcept {
      return session.pane_list_;
    }

    // The status of the focused agent the runtime last heard the user saw.
    [[nodiscard]] static constexpr AgentAcknowledgement& agentAcknowledgement(Session& session) noexcept {
      return session.agent_acknowledgement_;
    }

    // ---- the command blocks, which the session composes ------------------------------------

    // The keys of the command blocks, ahead of the editor's: what a key did to them, none when it
    // goes on to the editor.
    [[nodiscard]] static std::optional<features::prompt::Outcome> blockKey(Session& session, std::uint64_t pane_id, features::prompt::PaneLine& line, const features::prompt::KeyPress& key) {
      return session.blockKey(pane_id, line, key);
    }

    // ---- the tabs and panes the session holds ------------------------------------------------

    [[nodiscard]] static constexpr features::workbench::State& workbench(Session& session) noexcept {
      return session.workbench_;
    }

    [[nodiscard]] static constexpr const features::workbench::State& workbench(const Session& session) noexcept {
      return session.workbench_;
    }

    [[nodiscard]] static constexpr std::optional<TabLocation>& activeTab(Session& session) noexcept {
      return session.active_tab_;
    }

    // The tab at `location`, added to the model when the session holds none there.
    static Tab<Memory>& ensureTab(Session& session, TabLocation location) {
      return session.ensureTab(location);
    }

    // The pane `pane_id` in the tab at `location`, added to the model when the session holds none.
    static Pane<Memory>& ensurePane(Session& session, std::uint64_t pane_id, TabLocation location) {
      return session.ensurePane(pane_id, location);
    }

    // The panes the active tab shows attach, and the others detach.
    static void synchronizeAttachments(Session& session) {
      session.synchronizeAttachments();
    }

    // What a pane opened on its own runs: the launch's program and directory.
    [[nodiscard]] static Launch defaultLaunch(const Session& session) noexcept {
      return session.defaultLaunch();
    }

    // Asks the runtime to describe a tab, which it answers with a snapshot.
    static void requestSnapshot(Session& session, RequestTabSnapshot request) {
      session.sendSnapshotRequest(request);
    }

    // Asks the runtime to open a pane or a workspace, tracked as `kind` until it does.
    template <typename Request>
    static void open(Session& session, RequestKind kind, Request request) {
      session.sendOpeningRequest(kind, request);
    }

    // Leaves the active workspace for the one holding pane `pane_id`, else `fallback_workspace`.
    static void handoffPane(Session& session, std::uint64_t pane_id, std::optional<std::uint64_t> fallback_workspace) {
      session.handoffPane(pane_id, fallback_workspace);
    }

    // Leaves the active workspace for `target`, else `fallback_workspace`.
    static void handoffWorkspace(Session& session, PaneTarget target, std::optional<std::uint64_t> fallback_workspace) {
      session.handoffWorkspace(target, fallback_workspace);
    }

    // Sends a request to create, rename, move or close a tab, tracked until the runtime answers.
    template <typename Request>
    static void sendTabOperation(Session& session, RequestKind kind, Request request) {
      session.sendTabOperation(kind, request);
    }

    // The width of the sidebar in columns, which the layout the runtime retains carries.
    [[nodiscard]] static constexpr std::uint16_t sidebarColumns(const Session& session) noexcept {
      return session.sidebar_columns_;
    }

    // What the session answers a command of the CLI with, until the next one.
    [[nodiscard]] static constexpr String<Memory>& commandResponse(Session& session) noexcept {
      return session.command_response_;
    }

    // The session's clock, monotonic and in nanoseconds.
    [[nodiscard]] static std::uint64_t now(const Session& session) noexcept {
      return session.now_();
    }

    // ---- the desktop the session runs in ----------------------------------------------------

    [[nodiscard]] static constexpr HostEffects& effects(Session& session) noexcept {
      return session.effects_;
    }

    // ---- the connection with the runtime ----------------------------------------------------

    // Sends a limit report unless the transport is too busy for one; false when it dropped it.
    static bool report(Session& session, const ReportLimit& report) {
      return session.transport_.report(session.encode(report));
    }

    // Whether the transport hands images over in shared memory.
    [[nodiscard]] static bool sharesImages(const Session& session) noexcept {
      return session.supportsSharedGraphics();
    }

    [[nodiscard]] static system::SharedImageSource sharedImage(Session& session, std::string_view name) {
      return session.transport_.sharedImage(name);
    }

    // The connection failed under a request: the session recovers it.
    static void recoverRuntime(Session& session, std::string_view reason) {
      session.recoverRuntime(reason);
    }

    [[nodiscard]] static std::uint64_t nextRequest(Session& session) noexcept {
      return session.nextRequest();
    }

    template <typename Message>
    static void send(Session& session, const Message& message) {
      session.send(message);
    }

    // A request of `kind` the runtime will answer, tracked under a new id until it does.
    [[nodiscard]] static std::uint64_t pending(Session& session, RequestKind kind, std::uint64_t pane_id = 0, ClientLayoutAxis axis = ClientLayoutAxis::horizontal) {
      return session.pending(kind, pane_id, axis);
    }

    // What the session tracks of the request `pending` registered last, for its reply to read.
    [[nodiscard]] static constexpr Pending& lastPending(Session& session) noexcept {
      return session.pending_[session.pending_count_ - 1];
    }

    // The requests the runtime is yet to answer.
    [[nodiscard]] static constexpr std::span<const Pending> requests(const Session& session) noexcept {
      return std::span{session.pending_}.first(session.pending_count_);
    }

    // Sends `request` under a new pending id of `kind`; a request the transport refuses leaves
    // nothing pending.
    template <typename Request>
    static void sendRegistered(Session& session, RequestKind kind, Request request, std::uint64_t pane_id = 0) {
      session.sendRegistered(kind, request, pane_id);
    }

    static void complete(Session& session, std::uint64_t request_id) noexcept {
      static_cast<void>(session.complete(request_id));
    }

    // Completes `request_id` when it is a pending request of `kind`.
    [[nodiscard]] static bool completeRequest(Session& session, RequestKind kind, std::uint64_t request_id) noexcept {
      return session.completeRequest(kind, request_id);
    }
  };

}
