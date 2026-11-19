// What the use cases of application::<feature> reach of the state they compose. A partition the
// module does not export: only the module's own units import it, and ui cannot name Access.
module telar.gui.application:access;

import std;

import :session;
import telar.gui.features.paths;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.gui.features.peek;
import telar.gui.features.terminal.copy_mode;
import telar.gui.features.terminal.links;
import telar.base.ds;

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

    // ---- what the session keeps for every feature -------------------------------------------

    // The refresh rate of the display the session's window shows on.
    [[nodiscard]] static constexpr std::uint16_t& displayFps(Session& session) noexcept {
      return session.display_fps_;
    }

    [[nodiscard]] static constexpr ds::String<Memory>& clipboard(Session& session) noexcept {
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
    [[nodiscard]] static constexpr const ds::Option<TabLocation>& activeTab(const Session& session) noexcept {
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
    [[nodiscard]] static ds::Option<features::prompt::Outcome> blockKey(Session& session, std::uint64_t pane_id, const features::prompt::KeyPress& key) {
      return session.blockKey(pane_id, key);
    }

    // ---- the tabs and panes the session holds ------------------------------------------------

    // The tabs, to change them.
    [[nodiscard]] static std::span<ds::Box<Tab<Memory>, Memory>> tabsMut(Session& session) noexcept {
      return session.tabs.viewMut();
    }

    [[nodiscard]] static constexpr ds::Option<TabLocation>& activeTab(Session& session) noexcept {
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
    static void handoffPane(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> fallback_workspace) {
      session.handoffPane(pane_id, fallback_workspace);
    }

    // Leaves the active workspace for `target`, else `fallback_workspace`.
    static void handoffWorkspace(Session& session, PaneTarget target, ds::Option<std::uint64_t> fallback_workspace) {
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
    [[nodiscard]] static constexpr ds::String<Memory>& commandResponse(Session& session) noexcept {
      return session.command_response_;
    }

    // The session's clock, monotonic and in nanoseconds.
    [[nodiscard]] static std::uint64_t now(const Session& session) noexcept {
      return session.now_();
    }

    // The clock itself, for a use case that reads it while it holds one of the session's fields.
    [[nodiscard]] static MonotonicNow clock(const Session& session) noexcept {
      return session.now_;
    }

    // ---- the desktop the session runs in ----------------------------------------------------

    [[nodiscard]] static constexpr HostEffects& effects(Session& session) noexcept {
      return session.effects_;
    }

    // ---- the connection with the runtime ----------------------------------------------------

    // Sends a limit report unless the transport is too busy for one; false when it dropped it.
    static bool report(Session& session, const ReportLimit& report) {
      return session.link.transport.report(session.link.encode(report));
    }

    // Whether the transport hands images over in shared memory.
    [[nodiscard]] static bool sharesImages(const Session& session) noexcept {
      return session.supportsSharedGraphics();
    }

    [[nodiscard]] static system::SharedImageSource sharedImage(Session& session, std::string_view name) {
      return session.link.transport.sharedImage(name);
    }

    // The connection failed under a request: the session recovers it.
    static void recoverRuntime(Session& session, std::string_view reason) {
      session.recoverRuntime(reason);
    }

  };

}
