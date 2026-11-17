// What the use cases of application::<feature> reach of the state they compose. A partition the
// module does not export: only the module's own units import it, and ui cannot name Access.
module telar.gui.application:access;

import std;

import :session;
import telar.gui.prompt.line;
import telar.gui.features.palette;
import telar.gui.features.paths;
import telar.gui.features.history;
import telar.gui.features.peek;
import telar.gui.features.terminal.copy_mode;
import telar.gui.features.terminal.graphics;
import telar.gui.features.terminal.links;

namespace telar::gui::application {

  // Session befriends it; each accessor hands out one member, so a use case reaches what it
  // works on and the members stay out of Session's public interface. Accessors are added with
  // the use cases that need them, and stay inline so a use case costs what the method it
  // replaces did.
  struct Access {
    // The kinds of the requests Session tracks until the runtime answers them.
    using RequestKind = Session::RequestKind;

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

    [[nodiscard]] static constexpr features::terminal::links::State& links(Session& session) noexcept {
      return session.links_;
    }

    // ---- what the session keeps for every feature -------------------------------------------

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

    // ---- telar's command editor, until the prompt is a feature -----------------------------

    // The editor's line of pane `pane_id`, made on first use as the keys make it.
    [[nodiscard]] static prompt::Line& editorLine(Session& session, std::uint64_t pane_id) {
      return session.lineEntry(pane_id).line;
    }

    // The editor's line of pane `pane_id`, if it has one.
    [[nodiscard]] static prompt::Line* promptLine(Session& session, std::uint64_t pane_id) noexcept {
      const auto found = session.lines_.find(pane_id);

      return found == session.lines_.end() ? nullptr : &found->second.line;
    }

    // The editor of pane `pane_id` took text from outside the keyboard, for its view to show it.
    static void notePromptWrite(Session& session, std::uint64_t pane_id) noexcept {
      session.prompt_written_ = pane_id;
    }

    // ---- the workbench, until it is a feature -----------------------------------------------

    // Opens a tab, or the first pane, running `arguments`.
    static void launchTab(Session& session, std::span<const std::string_view> arguments) {
      session.launchTab(arguments);
    }

    // Splits pane `pane_id` beside a new pane running `arguments`; throws when it cannot.
    static void launchSplit(Session& session, std::uint64_t pane_id, std::span<const std::string_view> arguments) {
      session.launchSplit(pane_id, arguments);
    }

    // The tab at `location`, if the session holds it.
    [[nodiscard]] static Tab<Memory>* findTab(const Session& session, TabLocation location) noexcept {
      return session.findTab(location);
    }

    // The session's clock, monotonic and in nanoseconds.
    [[nodiscard]] static std::uint64_t now(const Session& session) noexcept {
      return session.now_();
    }

    // ---- the limits the session reports, shared by the features that reach one -------------

    static constexpr std::uint64_t limit_notice_duration_ns = Session::limit_notice_duration_ns;

    static LimitReports::Recorded countLimitReach(Session& session, LimitReach reach) {
      return session.countLimitReach(reach);
    }

    [[nodiscard]] static constexpr const LimitReports& limitReports(const Session& session) noexcept {
      return session.limit_reports_;
    }

    // ---- the connection with the runtime ----------------------------------------------------

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
    [[nodiscard]] static std::uint64_t pending(Session& session, RequestKind kind, std::uint64_t pane_id = 0) {
      return session.pending(kind, pane_id);
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
