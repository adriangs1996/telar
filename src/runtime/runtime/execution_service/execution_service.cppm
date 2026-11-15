module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.runtime.execution_service;

import std;
import telar.ghostty.vt;
import telar.tbc;

export import telar.runtime.model.client_layouts;
export import telar.base.diagnostics;

export import telar.runtime.platform.event_loop;
export import telar.runtime.transport.connection;

export import telar.platform.process;

export import telar.runtime.proxy.runtime;

export import :execution;
export import telar.runtime.shell_integration;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.execution;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.client;
import telar.platform.error;
import telar.platform.events;
import telar.platform.net;
import telar.runtime.platform.stream_read_buffer;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.shell_integration.words;
import telar.runtime.terminal.text_reader;
import telar.sys.posix;

// Interface: runtime/limit_service.cppm
export {
  namespace telar::runtime {

    // Limits the runtime and its clients reach. Any service may report one: a report is copied into a
    // fixed queue, and the runtime delivers the queue once no client is borrowed, recording each limit and
    // showing it to interactive clients. Nothing the service holds moves, so many services keep it.
    class TBC_SHARED LimitService {
    public:
      // Records a client's report at once, so a query in the same batch sees it; a control client's report
      // that is due is shown at the next delivery.
      void receive(RuntimeLimits& limits, ClientSession& client, const ReportLimit& message);

      void report(const LimitReach& reach) noexcept;

      static void query(ClientSession& client, const QueryLimits& request);

      // Records the reported limits and shows those that are due.
      void deliver(RuntimeModel& model, ClientStore& clients) noexcept;

    private:
      enum class Ledger : std::uint8_t {
        runtime,
        clients,
      };

      struct Reached {
        FixedText<64> name;
        FixedText<32> noun;
        FixedText<32> route;
        std::uint64_t value = 0;
        std::optional<std::uint64_t> requested;
      };

      void queueShow(Ledger ledger, std::size_t slot) noexcept;

      static bool admit(RuntimeLimits& limits, ClientSession& client) noexcept;

      static void show(ClientStore& clients, const LimitLedger::Row& row) noexcept;

      static constexpr unsigned reports_per_second = 32;
      std::array<Reached, 32> reached_{};
      std::size_t reports_ = 0;
      std::uint64_t dropped_ = 0;
      std::array<std::pair<Ledger, std::size_t>, 64> shown_{};
      std::size_t shows_ = 0;
    };

  }
}

// Interface: runtime/client_admission.cppm
export {
  namespace telar::runtime {

    template <EventLoop Poller>
    class ClientAdmission {
    public:
      explicit ClientAdmission(Poller& poller, LimitService& limits);

      ~ClientAdmission();

      void begin(std::size_t clients, FileDescriptor descriptor);

      // Generic over the caller's admission, a callable; the handshake advances in the implementation unit.
      template <typename Admit>
      TBC_GENERIC inline void event(const Event& event, const Admit& admit) {
        auto descriptor = advance(event);
        if (!descriptor) {
          return;
        }

        try {
          admit(std::move(*descriptor));
        } catch (const std::exception&) {
        }
      }

      void expire(std::chrono::steady_clock::time_point now) noexcept;

      void clear() noexcept;

    private:
      // Advances the handshake an event names; the descriptor of the client it accepts, if any.
      std::optional<FileDescriptor> advance(const Event& event);

      std::uint64_t token(std::size_t slot) const noexcept;

      void drop(std::size_t slot) noexcept;

      static constexpr std::size_t capacity = 16;
      std::array<std::optional<ClientHandshake>, capacity> pending_;
      std::array<std::uint64_t, capacity> generations_{};
      std::size_t count_ = 0;
      Poller& poller_;
      LimitService& limits_;
    };

    extern template class ClientAdmission<NativeEventLoop<ConcurrentMemory>>;

  }
}

// Interface: runtime/workspace_notifications.cppm
export {
  namespace telar::runtime {

    void notifyWorkspaceObservers(ClientStore& clients, std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous = {}) noexcept;

    std::optional<std::uint64_t> previousWorkspace(const WorkspaceStore& workspaces, std::uint64_t identity) noexcept;

  }
}

// Interface: runtime/geometry_lease.cppm
export {
  namespace telar::runtime {

    // The panes of a workspace whose geometry a client takes follow that client's colors.
    bool acquireGeometry(PaneStore& panes, [[maybe_unused]] diagnostics::RuntimeCounters& metrics, const ClientSession& client, Workspace& workspace);

    void releaseGeometry(ClientStore& clients, std::uint64_t client, Workspace& workspace) noexcept;

    void releaseAllGeometry(WorkspaceStore& workspaces, ClientStore& clients, std::uint64_t client) noexcept;

  }
}

// Interface: runtime/launch_failure_cause.cppm
export {
  namespace telar::runtime {

    std::string_view launchFailureCause(const std::exception& error) noexcept;

  }
}

// Interface: runtime/pane_launch_options.cppm
export {
  namespace telar::runtime {

    struct PaneLaunchOptions {
      std::string_view socket;
      ProxyClientConfiguration proxy{};
      control::Policy control_policy{};
      // The installed shell integration scripts; empty leaves shells as they start.
      std::string_view shell_integration{};
      // Whether an integrated shell's `ssh` brings the integration to the hosts it reaches.
      bool ssh_integration = false;
    };

  }
}

// Interface: runtime/pane_service.cppm
export {
  namespace telar::runtime {

    // Generic over the pane type of its caller; an empty observer importers inline away.
    struct IgnorePaneInput {
      template <typename PaneType>
      TBC_GENERIC inline void operator()(const PaneType&, std::span<const Byte>) const noexcept {}
    };

    // Kept whole: tests instantiate it with their own fake Poller and History (launch_failure_test's
    // FailingPoller and QueuedHistory).
    template <EventLoop Poller, HistoryEventSink History = DiscardedHistory>
    class TBC_GENERIC PaneService {
    public:
      // The panes it launches keep the allocator, and the service keeps what it is given, all in region `a`.
      inline explicit PaneService(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<Poller&, tbc::lt::a> poller, tbc::view<LimitService&, tbc::lt::a> limits, tbc::view<PaneLaunchOptions, tbc::lt::a> options, tbc::view<History&, tbc::lt::a> history = discarded_history)
          : memory_(memory),
            poller_(poller),
            limits_(limits),
            history_(history),
            socket_path_(options.socket),
            proxy_(options.proxy),
            control_policy_(options.control_policy),
            shell_integration_(memory, options.shell_integration, options.ssh_integration) {}

      inline static Pane& require(PaneStore& panes, std::uint64_t identity) {
        auto* pane = panes.find(identity);
        if (pane == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane does not exist"};
        }

        return *pane;
      }

      // Generation 0 names whatever generation the pane has, as requests from clients that predate
      // generations do.
      inline static Pane& requireGeneration(PaneStore& panes, std::uint64_t identity, std::uint64_t generation) {
        auto& pane = require(panes, identity);

        if (generation != 0 && findPane(panes, identity, generation) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane generation no longer exists"};
        }

        return pane;
      }

      // A new pane in a tab, in the colors of the workspace's geometry owner when there is one.
      // `bare_prompt`: the client it is for draws telar's editor, so its shell prints no prompt.
      inline tbc::view<Pane&, tbc::lt::a> launch(tbc::view<RuntimeModel&, tbc::lt::a> model, const ConfigureTerminalColors* owner_colors, bool bare_prompt, const Launch& launch, TabLocation location, TerminalSize size) {
        const auto identity = allocateIdentity(model);

        if (launch.environment_mode != EnvironmentMode::inherit_runtime || !launch.environment.empty()) {
          throw RequestError{FailureCode::invalid_request, "custom pane environment is not supported"};
        }

        Command command{memory_, launch};

        return launchPrepared(model, owner_colors, bare_prompt, command, location, size, identity);
      }

      inline tbc::view<Pane&, tbc::lt::a> launch(tbc::view<RuntimeModel&, tbc::lt::a> model, const ConfigureTerminalColors* owner_colors, bool bare_prompt, Command<ConcurrentMemory>& command, TabLocation location, TerminalSize size, std::uint64_t restored_identity = 0) {
        return launchPrepared(model, owner_colors, bare_prompt, command, location, size, allocateIdentity(model, restored_identity));
      }

      inline tbc::view<Attachment&, tbc::lt::a> attach(RuntimeModel& model, tbc::view<ClientSession&, tbc::lt::a> client, std::uint64_t pane_id, TerminalSize size) {
        auto* workspace = model.workspaces.find(require(model.panes, pane_id).location.workspace.id);
        if (workspace == nullptr) {
          throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
        }

        if (client.workspace && *client.workspace != workspace->id) {
          throw EncodingError{"Client must leave its workspace before attaching another"};
        }

        const bool controls_geometry = acquireGeometry(model.panes, model.metrics, client, *workspace);
        auto& pane = require(model.panes, pane_id);

        if (controls_geometry) {
          pane.resize(size);
        }

        if (auto* existing = client.attachment(pane.id)) {
          return *existing;
        }

        const auto slot = client.availableAttachmentSlot();
        // The attachment shares the pane's media through its own handle.
        auto media = pane.media;
        auto attachment = makeOwned<Attachment>(memory_, memory_, client.graphics_credit, pane.id, std::move(media));

        attachment->slot = slot;
        attachment->graphics.configure(client.shared_graphics);
        attachment->clipboard_revision = pane.terminal.effects.clipboard_revision;

        auto& result = *attachment;

        client.attachments.push_back(std::move(attachment));
        client.workspace = workspace->id;
        pane.observers |= client.observerBit();
        return result;
      }

      inline void detach(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, std::uint64_t identity) noexcept {
        if (!release(model, clients, client_id, identity)) {
          return;
        }

        if (const auto* client = clients.find(client_id); client != nullptr && client->attachments.empty()) {
          detachAll(model, clients, client_id);
        }
      }

      // Drops a client's attachment to a pane; whether it had one.
      inline bool release(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, std::uint64_t identity) noexcept {
        auto* client = clients.find(client_id);
        if (client == nullptr) {
          return false;
        }

        const auto bit = client->observerBit();
        const auto removed = std::erase_if(client->attachments, [identity](const auto& attachment) {
          return attachment->pane_id == identity;
        });

        if (auto* pane = model.panes.find(identity)) {
          pane->observers &= ~bit;
          refreshAfterDetach(model, clients, identity);
        }

        return removed != 0;
      }

      inline void detachAll(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id) noexcept {
        auto* client = clients.find(client_id);
        if (client == nullptr) {
          return;
        }

        const auto bit = client->observerBit();
        std::array<std::uint64_t, ClientSession::attachment_capacity> detached{};
        std::size_t count = 0;

        for (const auto& attachment : client->attachments) {
          attachment->desktop.reset();
          if (auto* pane = model.panes.find(attachment->pane_id)) {
            pane->observers &= ~bit;
            detached[count++] = pane->id;
          }
        }

        const auto workspace = client->workspace;

        client->attachments.clear();
        client->workspace.reset();
        if (workspace) {
          if (auto* leased = model.workspaces.find(*workspace)) {
            releaseGeometry(clients, client_id, *leased);
          }
        }

        for (const auto pane : std::span{detached}.first(count)) {
          refreshAfterDetach(model, clients, pane);
        }
      }

      inline void remove(RuntimeModel& model, ClientStore& clients, std::uint64_t identity) noexcept {
        auto* pane = model.panes.find(identity);
        if (pane == nullptr) {
          return;
        }

        bool released = false;

        for (auto* client : clients.items()) {
          if (client != nullptr && std::erase_if(client->attachments, [identity](const auto& attachment) {
                return attachment->pane_id == identity;
              }) != 0) {
            pane->observers &= ~client->observerBit();
            released = true;
          }
        }

        if (released) {
          refreshAfterDetach(model, clients, identity);
        }

        auto& removed = require(model.panes, identity);

        poller_.remove(removed.process->descriptor());
        if (removed.exit_status && !removed.exit_observed) {
          removed.observer->shellExit(*removed.exitCode());
          removed.exit_observed = true;
        }

        removed.observer->finishSession();
        removed.media->cancel();
        removed.observer->retired_next = std::move(model.retired_observers);
        model.retired_observers = removed.observer;
        ++model.retired_observer_count;
        removed.media->retired_next = std::move(model.retired_media);
        model.retired_media = removed.media;
        ++model.retired_media_count;
        model.panes.erase(identity);
        ++model.pane_revision;
      }

      template <typename Observer = IgnorePaneInput>
      inline void input(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PaneInput& request, const Observer& observe = {}) {
        if (const auto* client = clients.find(client_id); client == nullptr || client->attachment(request.pane_id) == nullptr) {
          return;
        }

        auto& pane = require(model.panes, request.pane_id);
        if (pane.output_closed) {
          return;
        }

        if (admitInput(pane, request.bytes.size())) {
          pane.enqueueInput(request.bytes);
          observe(pane, request.bytes);
          pane.last_input = std::chrono::steady_clock::now();
          flushInput(pane);
        }

        recordInputOrigin(model, clients, client_id, request.pane_id);
        ClipboardService::configure(clients, require(model.panes, request.pane_id));
      }

      inline static std::size_t typedSize(bool paste, std::span<const Byte> text, std::span<const Byte> enter) noexcept {
        return BracketedPaste::size(text.size(), paste) + enter.size();
      }

      // Types a line at a pane: the prefix and the text, as one paste when `paste`, then `enter`. The
      // prefix ends in a space, so no terminator spans it and the text.
      template <typename Observer>
      inline static void type(Pane& pane, bool paste, std::span<const Byte> prefix, std::span<const Byte> text, std::span<const Byte> enter, const Observer& observe) {
        const auto forward = [&](std::span<const Byte> bytes) {
          pane.enqueueInput(bytes);
          observe(pane, bytes);
        };

        if (!paste) {
          forward(prefix);
          forward(text);
        } else {
          const auto piece = [&](std::string_view bytes) {
            forward({reinterpret_cast<const Byte*>(bytes.data()), bytes.size()});
          };

          piece(BracketedPaste::begin);
          BracketedPaste::body(textView(prefix), piece);
          BracketedPaste::body(textView(text), piece);
          piece(BracketedPaste::end);
        }

        if (!enter.empty()) {
          forward(enter);
        }
      }

      // Writes a paste to a pane's input queue, framed when its program asked for bracketed paste.
      inline static void paste(Pane& pane, std::span<const Byte> text, bool bracketed) {
        BracketedPaste::encode(textView(text), bracketed, [&](std::string_view bytes) {
          pane.enqueueInput({reinterpret_cast<const Byte*>(bytes.data()), bytes.size()});
        });
      }

      [[nodiscard]] inline static std::string_view textView(std::span<const Byte> bytes) noexcept {
        return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
      }

      inline bool admitInput(Pane& pane, std::size_t bytes) {
        if (bytes <= Pane::input_limit - pane.input.size()) {
          return true;
        }

        TELAR_DIAGNOSTIC(diagnostics::accumulate(pane.input_dropped_bytes, bytes));
        limits_.report(LimitReach{.name = "panes.input_queue_capacity", .noun = "queued input bytes", .value = Pane::input_limit, .requested = saturatedAdd(pane.input.size(), bytes)});
        return false;
      }

      inline void resize(RuntimeModel& model, ClientSession& client, const PaneResize& request) {
        if (client.attachment(request.pane_id) == nullptr) {
          return;
        }

        auto* workspace = model.workspaces.find(require(model.panes, request.pane_id).location.workspace.id);
        if (workspace == nullptr || !acquireGeometry(model.panes, model.metrics, client, *workspace)) {
          return;
        }

        require(model.panes, request.pane_id).resize(request.size);
      }

      inline void flushInput(Pane& pane) {
        if (pane.output_closed) {
          return;
        }

        if (pane.media->failed()) {
          failOutput(pane);
          return;
        }

        try {
          pane.resumeControl();
          pane.write();
          const bool needs_write = pane.hasInput();
          if (needs_write != pane.write_interest) {
            poller_.writeInterest(pane.process->descriptor(), eventToken(EventSource::pane, pane.event_identity), needs_write);
            pane.write_interest = needs_write;
          }
        } catch (const std::exception&) {
          failOutput(pane);
        }
      }

      inline void failOutput(Pane& pane) noexcept {
        pane.terminal.abortControl();
        pane.media->cancel();
        pane.requestClose();
        pane.output_closed = true;
        poller_.remove(pane.process->descriptor());
      }

      inline void configureDesktop(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const ConfigurePaneDesktop& request) {
        const auto pane = requireGeneration(model.panes, request.pane_id, request.pane_generation).id;
        auto* client = clients.find(client_id);
        auto* attachment = client == nullptr ? nullptr : client->attachment(pane);
        if (attachment == nullptr || client->connection.closing) {
          throw RequestError{FailureCode::invalid_request, "Desktop state requires a live pane attachment"};
        }

        if (attachment->desktop == request) {
          return;
        }

        attachment->desktop = request;
        refreshDesktop(model, clients, pane);
        flushInput(require(model.panes, pane));
      }

      inline void configureColors(RuntimeModel& model, ClientSession& client, const ConfigureTerminalColors& request) {
        if (client.colors.foreground == request.foreground && client.colors.background == request.background && client.colors.palette == request.palette) {
          return;
        }

        client.colors = request;
        for (auto* pane : model.panes.items()) {
          const auto* workspace = pane == nullptr ? nullptr : model.workspaces.find(pane->location.workspace.id);
          if (workspace != nullptr && workspace->geometry_client == client.id && !pane->desktop_theme) {
            pane->terminal.configureColors(request);
            flushInput(*pane);
          }
        }
      }

      inline static void readText(ClientSession& client, const ReadPane& request) {
        client.connection.defer(request);
      }

      inline void copySelection(PaneStore& panes, ClientSession& client, const CopySelection& request) {
        if (client.attachment(request.pane_id) == nullptr) {
          return;
        }

        auto& pane = require(panes, request.pane_id);
        constexpr std::size_t clipboard_limit = 1024 * 1024;
        TextReader reader{memory_, pane.terminal, clipboard_limit};

        reader.copy(request);
        if (reader.truncated()) {
          throw RequestError{FailureCode::resource_limit, "Selection exceeds the clipboard limit"};
        }

        client.clipboard.replace(pane.id, reader.bytes());
      }

      // A command a client runs at the prompt of a pane it shows. Its text is recorded for the
      // command's history, then typed as a prompt sent with sendText is.
      template <typename Observer = IgnorePaneInput>
      inline void command(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PaneCommand& request, const Observer& observe = {}) {
        if (const auto* client = clients.find(client_id); client == nullptr || client->attachment(request.pane_id) == nullptr) {
          return;
        }

        auto& pane = require(model.panes, request.pane_id);
        if (pane.output_closed) {
          return;
        }

        const bool paste = pane.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
        std::array<Byte, 128> encoded_enter;
        const auto enter = pane.terminal.encodeKey(GHOSTTY_KEY_ENTER, 0, encoded_enter);
        if (admitInput(pane, typedSize(paste, request.text, enter))) {
          pane.submitCommand(request.text);
          type(pane, paste, {}, request.text, enter, observe);
          pane.last_input = std::chrono::steady_clock::now();
          flushInput(pane);
        }

        recordInputOrigin(model, clients, client_id, request.pane_id);
        ClipboardService::configure(clients, require(model.panes, request.pane_id));
      }

      template <typename Observer = IgnorePaneInput>
      inline void sendText(PaneStore& panes, ClientSession& client, const SendPaneText& request, std::string_view prefix = {}, const Observer& observe = {}) {
        auto& pane = requireGeneration(panes, request.pane_id, request.pane_generation);
        if (pane.output_closed) {
          throw RequestError{FailureCode::pane_exited, "Pane process has exited"};
        }

        const auto text = std::span<const Byte>{reinterpret_cast<const Byte*>(request.text.data()), request.text.size()};
        const bool paste = request.mode == PaneTextMode::prompt && pane.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
        std::array<Byte, 128> encoded_enter;
        const auto enter = request.mode == PaneTextMode::raw ? std::span<const Byte>{} : pane.terminal.encodeKey(GHOSTTY_KEY_ENTER, 0, encoded_enter);
        const auto required = prefix.size() + typedSize(paste, text, enter);
        if (!admitInput(pane, required)) {
          std::array<char, 160> message;
          const auto length = std::snprintf(message.data(), message.size(), "the pane's input queue holds its limit of %zu bytes; the program in it is not reading input", Pane::input_limit);

          client.connection.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::resource_limit, .message = {message.data(), static_cast<std::size_t>(length)}});
          return;
        }

        type(pane, paste, {reinterpret_cast<const Byte*>(prefix.data()), prefix.size()}, text, enter, observe);
        if (request.mode != PaneTextMode::raw || request.text.find('\r') != std::string_view::npos) {
          pane.observer->noteInjectedSubmission();
        }

        pane.last_input = std::chrono::steady_clock::now();
        flushInput(pane);
        client.connection.send(RequestCompleted{.request_id = request.request_id});
      }

      inline void pasteClipboard(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PastePaneClipboard& request) {
        auto& pane = requireGeneration(model.panes, request.pane_id, request.pane_generation);
        auto* client = clients.find(client_id);
        if (client == nullptr || !ClipboardService::eligible(*client, pane) || pane.output_closed) {
          throw RequestError{FailureCode::invalid_request, "Clipboard paste requires a live visible attachment"};
        }

        if (request.listing_only) {
          // A listing begun before a mode reset completes without reading text.
          if (pane.terminal.pasteEvents()) {
            if (!pane.terminal.clipboardControl().paste({client->id, client->generation}, request.primary, request.available)) {
              throw RequestError{FailureCode::resource_limit, "Clipboard response is pending"};
            }

            pane.resumeControl();
          }
        } else if (!request.text.empty()) {
          const bool bracketed = pane.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
          if (!admitInput(pane, typedSize(bracketed, request.text, {}))) {
            throw RequestError{FailureCode::resource_limit, "Paste exceeds available pane input capacity"};
          }

          paste(pane, request.text, bracketed);
        }

        recordInputOrigin(model, clients, client_id, request.pane_id);
        flushInput(require(model.panes, request.pane_id));
        if (auto* current = clients.find(client_id)) {
          current->connection.send(RequestCompleted{.request_id = request.request_id});
        }
      }

      // A search of the whole scrollback, or of some rows of it.
      template <typename Request>
        requires std::same_as<Request, SearchPane> || std::same_as<Request, SearchPaneRows>
      inline static void search(PaneStore& panes, ClientSession& client, const Request& request) {
        auto& pane = require(panes, request.pane_id);
        if (client.role == ClientRole::interactive && client.attachment(pane.id) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane is not attached"};
        }

        if (client.search) {
          client.connection.send(RequestFailed{.request_id = client.search->request_id, .code = FailureCode::resource_limit, .message = "Pane search superseded"});
        }

        client.search.emplace(request, pane.terminal.contentRevision());
      }

      // Rows of an attached pane's scrollback, which its client draws while it scrolls.
      inline static void readRows(PaneStore& panes, ClientSession& client, const ReadPaneRows& request) {
        auto& pane = require(panes, request.pane_id);
        if (client.attachment(pane.id) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane is not attached"};
        }

        client.connection.send(pane.scrollback_rows.read(pane.terminal, request));
      }

      inline static bool advanceSearch(PaneStore& panes, ClientSession& client) {
        if (!client.search) {
          return false;
        }

        try {
          auto& pane = require(panes, client.search->pane_id);
          if (client.search->advance(pane.terminal.handle(), pane.terminal.contentRevision())) {
            client.connection.send(client.search->result());
            client.search.reset();
          }
        } catch (const std::exception&) {
          client.connection.send(RequestFailed{.request_id = client.search->request_id, .code = FailureCode::resource_limit, .message = "Pane search stopped; retry"});
          client.search.reset();
        }

        return client.search.has_value();
      }

    private:
      inline static void recordInputOrigin(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, std::uint64_t pane) noexcept {
        ++model.input_sequence;
        if (model.input_sequence == 0) {
          for (auto* session : clients.items()) {
            if (session != nullptr) {
              session->last_input_sequence = 0;
            }
          }

          model.input_sequence = 1;
        }

        if (auto* client = clients.find(client_id)) {
          client->last_input_pane = pane;
          client->last_input_sequence = model.input_sequence;
        }
      }

      // Visibility is the union of explicit live reports. The oldest visible
      // reporter supplies theme facts; focus and the geometry lease cannot steal it.
      inline static void refreshDesktop(RuntimeModel& model, const ClientStore& clients, std::uint64_t identity) {
        auto& pane = require(model.panes, identity);
        control::ClientFacts facts;
        const ConfigurePaneDesktop* theme = nullptr;
        std::uint64_t theme_client = std::numeric_limits<std::uint64_t>::max();

        for (const auto* client : clients.items()) {
          if (client == nullptr || client->connection.closing) {
            continue;
          }

          const auto* attachment = client->attachment(pane.id);
          if (attachment == nullptr || !attachment->desktop || attachment->desktop->pane_generation != pane.generation) {
            continue;
          }

          const auto& desktop = *attachment->desktop;

          facts.visible |= desktop.visible;
          facts.focused |= desktop.focused && desktop.visible;
          if (desktop.visible && client->id < theme_client) {
            theme_client = client->id;
            theme = &desktop;
          }
        }

        if (theme != nullptr) {
          facts.light = theme->light;
          const auto& previous = pane.desktop_theme;
          if (!previous || previous->foreground != theme->foreground || previous->background != theme->background || previous->palette != theme->palette || previous->cursor != theme->cursor) {
            pane.terminal.configureColors({theme->foreground, theme->background, theme->palette});
            pane.terminal.configureCursorColor(theme->cursor);
          }

          pane.desktop_theme = *theme;
        } else if (pane.desktop_theme) {
          pane.desktop_theme.reset();
          const auto* workspace = model.workspaces.find(pane.location.workspace.id);
          const auto* owner = workspace != nullptr && workspace->geometry_client ? clients.find(*workspace->geometry_client) : nullptr;

          pane.terminal.configureColors(owner != nullptr && !owner->connection.closing ? owner->colors : ConfigureTerminalColors{});
          pane.terminal.configureCursorColor(std::nullopt);
        }

        pane.terminal.configureClientFacts(facts);
        ClipboardService::configure(clients, pane);
      }

      struct Identity {
        std::uint64_t id;
        std::uint64_t generation;
      };

      inline static Identity allocateIdentity(RuntimeModel& model, std::uint64_t restored_identity = 0) {
        if (model.panes.size() + std::max(model.retired_observer_count, model.retired_media_count) >= pane_capacity) {
          throw RequestError{FailureCode::resource_limit, "Pane capacity is occupied by active processes or pending observations"};
        }

        if (model.next_pane_generation == 0 || model.next_pane_generation == std::numeric_limits<std::uint64_t>::max() || (restored_identity == 0 && model.panes.nextCounter() == 0)) {
          throw RequestError{FailureCode::spawn_failed, "could not start the command"};
        }

        const auto identity = restored_identity == 0 ? model.panes.nextId() : restored_identity;

        model.panes.advanceCounter(identity + 1);
        return {identity, model.next_pane_generation++};
      }

      inline tbc::view<Pane&, tbc::lt::a> launchPrepared(tbc::view<RuntimeModel&, tbc::lt::a> model, const ConfigureTerminalColors* owner_colors, bool bare_prompt, Command<ConcurrentMemory>& command, TabLocation location, TerminalSize size, Identity identity) {
        const auto setIdentity = [&](std::string_view name, std::uint64_t value) {
          std::array<char, 32> text{};
          const auto converted = std::to_chars(text.data(), text.data() + text.size(), value);

          command.setEnvironment(name, {text.data(), converted.ptr});
        };

        setIdentity("TELAR_PANE_ID", identity.id);
        setIdentity("TELAR_PANE_GENERATION", identity.generation);
        setIdentity("TELAR_WORKSPACE_ID", location.workspace.id);
        setIdentity("TELAR_TAB_ID", location.tab_id);
        command.setEnvironment("TELAR_SOCKET_PATH", socket_path_);
        if (!model.cli_executable.empty()) {
          command.setEnvironment("TELAR_BIN_PATH", model.cli_executable);
        }

        proxy_.apply(command);
        const auto shell = shell_integration_.apply(command, bare_prompt);
        auto pane = makeOwned<Pane>(memory_, memory_, identity.id, location, command, PaneLaunch{size, model.media_budget, model.graphics_limits, shell});

        TELAR_DIAGNOSTIC(pane->counters = &model.metrics.panes);
        pane->generation = identity.generation;
        pane->terminal.controlPolicy() = control_policy_;
        const auto* workspace = model.workspaces.find(location.workspace.id);
        const HistorySession session{.id = pane->history_session, .pane = pane->id, .location = location, .started_at_ms = ObservationTime::now().milliseconds, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .shell = command.arguments().front()};
        auto phase = LaunchPhase::pane_registration;
        bool registered = false;

        try {
          if (owner_colors != nullptr) {
            pane->terminal.configureColors(*owner_colors);
          }

          pane->observer->configureHistory(session, model.capture_output);
          const auto handle = model.panes.insert(identity.id, std::move(pane));

          registered = true;
          ++model.pane_revision;
          // The pane now lives in the table, where it is found again.
          auto& inserted = *model.panes.find(identity.id);

          inserted.event_identity = handle;
          if (handle > maximum_event_identity) {
            throw RequestError{FailureCode::resource_limit, "Pane event identity space exhausted"};
          }

          phase = LaunchPhase::output_actor;
          poller_.watch(inserted.process->descriptor(), eventToken(EventSource::pane, handle));
        } catch (const std::exception& error) {
          history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::launch_failed, .session = session, .finished_at_ms = ObservationTime::now().milliseconds, .failure = {identity.generation, phase, launchFailureCause(error)}});
          if (registered) {
            poller_.remove(model.panes.find(identity.id)->process->descriptor());
            model.panes.erase(identity.id);
            ++model.pane_revision;
          }

          throw;
        }

        return *model.panes.find(identity.id);
      }

      inline void refreshAfterDetach(RuntimeModel& model, const ClientStore& clients, std::uint64_t identity) noexcept {
        try {
          refreshDesktop(model, clients, identity);
          flushInput(require(model.panes, identity));
        } catch (...) {
          if (auto* pane = model.panes.find(identity)) {
            pane->requestClose();
          }
        }
      }

      static constexpr std::size_t pane_capacity = 256;

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      tbc::view<Poller&, tbc::lt::a> poller_;
      tbc::view<LimitService&, tbc::lt::a> limits_;
      tbc::view<History&, tbc::lt::a> history_;
      tbc::view<std::string_view, tbc::lt::a> socket_path_;
      ProxyClientConfiguration proxy_;
      control::Policy control_policy_;
      tbc::view<ShellIntegration<ConcurrentMemory>, tbc::lt::a> shell_integration_;
    };

  }
}

// Interface: runtime/execution_service.cppm
export {
  namespace telar::runtime {

    template <EventLoop Poller>
    class ExecutionService {
    public:
      explicit ExecutionService(ConcurrentMemory& memory, Poller& poller, LimitService& limits);

      ~ExecutionService();

      void request(RuntimeModel& model, ClientSession& client, const ExecutionRequest& request);

      void event(const Event& event);

      bool refresh(RuntimeModel& model) noexcept;

      void disconnect(std::uint64_t client_id);

    private:
      Execution<ConcurrentMemory>* find(std::uint64_t identity) const noexcept;

      Execution<ConcurrentMemory>& start(RuntimeModel& model, std::uint64_t client_id, const ExecutionRequest& request);

      std::uint64_t administration(RuntimeModel& model);

      void releaseAdministration(RuntimeModel& model) noexcept;

      void receiveInput(Execution<ConcurrentMemory>& execution, std::uint64_t client_id, const ExecutionRequest& request);

      static void flushInput(Poller& poller, Execution<ConcurrentMemory>& execution);

      static void closeInput(Poller& poller, Execution<ConcurrentMemory>& execution) noexcept;

      static void unwatch(Poller& poller, Execution<ConcurrentMemory>& execution) noexcept;

      // The reply to the request that started an execution says `starting`,
      // before the spawning thread confirms the child; later replies report it
      // running.
      void send(ClientSession& client, const Execution<ConcurrentMemory>& execution, const ExecutionRequest& request, bool started = false);

      void list(ClientSession& client, const ExecutionRequest& request);

      static constexpr std::size_t capacity = 32;
      ConcurrentMemory& memory_;
      Poller& poller_;
      LimitService& limits_;
      SlotStore<Execution<ConcurrentMemory>, capacity, ConcurrentMemory> executions_;
      std::uint64_t administration_ = 0;
    };

    extern template class ExecutionService<NativeEventLoop<ConcurrentMemory>>;

  }
}
