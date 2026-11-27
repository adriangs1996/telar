module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.core.execution_service;

import std;
import telar.ghostty.vt;
import telar.tbc;

import telar.runtime.core.model.client_layouts;
import telar.base.diagnostics;

import telar.runtime.host.event_loop;
import telar.runtime.transport.connection;

import telar.platform.process;

import telar.runtime.traffic.proxy.client_configuration;

export import :execution;
import telar.runtime.terminal.shell_integration;
import telar.base.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.execution;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;
import telar.client;
import telar.platform.events;
import telar.runtime.host.stream_read_buffer;
import telar.runtime.core.delivery.client_delivery;
import telar.runtime.terminal.text_reader;
import telar.sys.posix;
import telar.config.runtime;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.history.event;
import telar.runtime.core.model.slot_store;
import telar.runtime.nvim.editor;
import telar.runtime.files.moves;
import telar.runtime.nvim.provision;
import telar.base.ds;

// Interface: runtime/limit_service.cppm
export {
  namespace telar::runtime {

    // Limits the runtime and its clients reach. Any service may report one: a report is copied into a
    // fixed queue, and the runtime delivers the queue once no client is borrowed, recording each limit and
    // showing it to interactive clients. Nothing the service holds moves, so many services keep it.
    class [[tbc::shared]] LimitService {
    public:
      LimitService() = default;
      ~LimitService() = default;
      LimitService(const LimitService&) = delete;
      LimitService& operator=(const LimitService&) = delete;
      LimitService(LimitService&&) = delete;
      LimitService& operator=(LimitService&&) = delete;

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
        FixedText<LimitLedger::Row::name_bytes> name;
        FixedText<LimitLedger::Row::noun_bytes> noun;
        FixedText<LimitLedger::Row::route_bytes> route;
        std::uint64_t value = 0;
        ds::Option<std::uint64_t> requested;
      };

      void queueShow(Ledger ledger, std::size_t slot) noexcept;

      static bool admit(RuntimeLimits& limits, ClientSession& client) noexcept;

      static void show(ClientStore& clients, const LimitLedger::Row& row) noexcept;

      static constexpr unsigned reports_per_second = 32;
      // The reports and shows held between two deliveries.
      static constexpr std::size_t held_reports = 32;
      static constexpr std::size_t held_shows = 64;

      ds::Array<Reached, held_reports> reached_{};
      std::size_t reports_ = 0;
      std::uint64_t dropped_ = 0;
      ds::Array<std::pair<Ledger, std::size_t>, held_shows> shown_{};
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

      ClientAdmission(const ClientAdmission&) = delete;
      ClientAdmission& operator=(const ClientAdmission&) = delete;
      ClientAdmission(ClientAdmission&&) = delete;
      ClientAdmission& operator=(ClientAdmission&&) = delete;

      void begin(std::size_t clients, FileDescriptor descriptor);

      // Generic over the caller's admission, a callable; the handshake advances in the implementation unit.
      template <typename Admit>
      [[tbc::generic]] inline void event(const Event& event, const Admit& admit) {
        auto descriptor = advance(event);
        if (!descriptor) {
          return;
        }

        try {
          admit(std::move(descriptor.getMut()));
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a client the runtime cannot admit is closed with its descriptor; the others carry on
        }
      }

      void expire(std::chrono::steady_clock::time_point now) noexcept;

      void clear() noexcept;

    private:
      // Advances the handshake an event names; the descriptor of the client it accepts, if any.
      ds::Option<FileDescriptor> advance(const Event& event);

      [[nodiscard]] std::uint64_t token(std::size_t slot) const noexcept;

      void drop(std::size_t slot) noexcept;

      static constexpr std::size_t capacity = 16;
      ds::Array<ds::Option<ClientHandshake>, capacity> pending_;
      ds::Array<std::uint64_t, capacity> generations_{};
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

    void notifyWorkspaceObservers(ClientStore& clients, std::uint64_t workspace, std::uint64_t origin, ds::Option<std::uint64_t> previous = {}) noexcept;

    ds::Option<std::uint64_t> previousWorkspace(const WorkspaceStore& workspaces, std::uint64_t identity) noexcept;

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
      ProxyClientConfiguration proxy;
      control::Policy control_policy{};
      // The installed shell integration scripts; empty leaves shells as they start.
      std::string_view shell_integration;
      // Whether an integrated shell's `ssh` brings the integration to the hosts it reaches.
      bool ssh_integration = false;
      // Whether a pane turns on the plan tools an agent keeps off by default.
      bool agent_plans = true;
    };

  }
}

// Interface: runtime/pane_service.cppm
export {
  namespace telar::runtime {

    // Generic over the pane type of its caller; an empty observer importers inline away.
    struct IgnorePaneInput {
      template <typename PaneType>
      [[tbc::generic]] inline void operator()(const PaneType& /*pane*/, std::span<const Byte> /*bytes*/) const noexcept {}
    };

    // Where a pane launches, and how its terminal and shell start. `bare_prompt`: the client it is
    // for draws telar's editor, so its shell prints no prompt.
    struct PanePlacement {
      const ConfigureTerminalColors* owner_colors = nullptr;
      bool bare_prompt = false;
      TabLocation location;
      TerminalSize size{};
    };

    // A client's attachment to a pane, by the ids of both.
    struct AttachmentKey {
      std::uint64_t client = 0;
      std::uint64_t pane = 0;
    };

    // Kept whole: tests instantiate it with their own fake Poller and History (launch_failure_test's
    // FailingPoller and QueuedHistory).
    template <EventLoop Poller, HistoryEventSink History = DiscardedHistory>
    class [[tbc::generic]] PaneService {
    public:
      // The panes it launches keep the allocator, and the service keeps what it is given, all in region `a`.
      inline explicit PaneService(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<Poller> poller, tbc::mut_a<LimitService> limits, tbc::val_a<PaneLaunchOptions> options, tbc::mut_a<History> history = discarded_history) // NOLINT(performance-unnecessary-value-param): taken by value, the label says the views the options hold live in region `a`; a reference would demand it of the options themselves
          : memory_(memory),
            poller_(poller),
            limits_(limits),
            history_(history),
            socket_path_(options.socket),
            proxy_(options.proxy),
            control_policy_(options.control_policy),
            shell_integration_(memory, options.shell_integration, options.ssh_integration),
            agent_plans_(options.agent_plans) {}

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

        if (generation != 0 && findPane(panes, {.id = identity, .generation = generation}) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane generation no longer exists"};
        }

        return pane;
      }

      // The terminal a request names: a request only a terminal answers is refused for another kind.
      inline static PaneRef<TerminalBody> requireTerminal(PaneStore& panes, std::uint64_t identity) {
        return telar::runtime::requireTerminal(require(panes, identity));
      }

      inline static PaneRef<TerminalBody> requireTerminalGeneration(PaneStore& panes, std::uint64_t identity, std::uint64_t generation) {
        return telar::runtime::requireTerminal(requireGeneration(panes, identity, generation));
      }

      // A new pane in a tab, in the colors of the workspace's geometry owner when there is one.
      inline tbc::val_a<PaneRef<TerminalBody>> launch(tbc::mut_a<RuntimeModel> model, const PanePlacement& placement, const Launch& launch) {
        const auto identity = allocateIdentity(model);

        if (launch.environment_mode != EnvironmentMode::inherit_runtime || !launch.environment.empty()) {
          throw RequestError{FailureCode::invalid_request, "custom pane environment is not supported"};
        }

        Command command{memory_, launch};

        return launchPrepared(model, placement, command, identity);
      }

      inline tbc::val_a<PaneRef<TerminalBody>> launch(tbc::mut_a<RuntimeModel> model, const PanePlacement& placement, Command<ConcurrentMemory>& command, std::uint64_t restored_identity = 0) {
        return launchPrepared(model, placement, command, allocateIdentity(model, restored_identity));
      }

      // A new editor pane in a tab: `launch` starts a Neovim with --embed, which the pane is the
      // only UI of. Its output, its errors and its input are three descriptors of one pane.
      inline tbc::val_a<PaneRef<NvimBody>> launchEditor(tbc::mut_a<RuntimeModel> model, const PanePlacement& placement, const Launch& launch, std::uint64_t restored_identity = 0) {
        const auto identity = allocateIdentity(model, restored_identity);
        // Its plugins and its state are kept apart from the user's own Neovim, and from telar's
        // files, whether it starts now or comes back with a session.
        Launch started = launch;

        if (started.environment.empty()) {
          started.environment = nvimEnvironment(launch.arguments);
        }

        Command command{memory_, started, CommandPurpose::configured_helper};

        identify(command, model, placement, identity);
        proxy_.apply(command);
        auto pane = ds::makeBox<Pane>(memory_, memory_, identity.id, placement.location, command, placement.size);

        pane.getMut().generation = identity.generation;
        const auto handle = model.panes.insert(identity.id, std::move(pane));

        ++model.pane_revision;
        try {
          auto inserted = requireNvim(model.panes, identity.id);

          inserted.core.event_identity = handle;
          if (handle > maximum_event_identity) {
            throw RequestError{FailureCode::resource_limit, "Pane event identity space exhausted"};
          }

          const auto token = eventToken(EventSource::pane, handle);

          poller_.watch(inserted.body.process->output(), token);
          poller_.watch(inserted.body.process->error(), token);
          // The editor's colorscheme is its owner's theme, as a terminal's palette is.
          if (placement.owner_colors != nullptr) {
            inserted.body.editor.theme(*placement.owner_colors);
          }

          flushEditor(inserted);
        } catch (...) {
          if (const auto failed = asNvim(model.panes.find(identity.id))) {
            release(*failed);
          }

          model.panes.erase(identity.id);
          ++model.pane_revision;
          throw;
        }

        return requireNvim(model.panes, identity.id);
      }

      // A new explorer pane in a tab, with the windows `layout` gives it. It starts no program
      // and watches no descriptor.
      inline tbc::val_a<PaneRef<ExplorerBody>> launchExplorer(tbc::mut_a<RuntimeModel> model, const PanePlacement& placement, std::string_view directory, std::uint64_t restored_identity = 0) {
        const auto identity = allocateIdentity(model, restored_identity);
        auto pane = ds::makeBox<Pane>(memory_, memory_, identity.id, placement.location, Pane::Explorer{.directory = directory, .size = placement.size});

        pane.getMut().generation = identity.generation;
        const auto handle = model.panes.insert(identity.id, std::move(pane));

        ++model.pane_revision;
        auto inserted = requireExplorer(model.panes, identity.id);

        inserted.core.event_identity = handle;
        return inserted;
      }

      // Writes what an editor queued for its Neovim, and asks to be woken while some is left.
      inline void flushEditor(PaneRef<NvimBody> pane) {
        if (pane.core.close_requested || pane.body.process->input() < 0) {
          return;
        }

        pane.body.write();
        const bool waiting = pane.body.hasInput();
        if (waiting != pane.core.write_interest) {
          pane.core.write_interest = waiting;
          poller_.writeInterest(pane.body.process->input(), eventToken(EventSource::pane, pane.core.event_identity), waiting);
        }
      }

      // Hands the editor of a pane the client is attached to to `request`, which queues what the
      // client asked of Neovim, then writes it. A client that is not attached asks nothing, as
      // with a terminal's input; an editor that takes no more is closed.
      template <typename Request>
      inline void editorRequest(RuntimeModel& model, const ClientSession& client, std::uint64_t pane_id, Request&& request) {
        if (client.attachment(pane_id) == nullptr) {
          return;
        }

        auto pane = requireNvim(model.panes, pane_id);
        if (pane.core.close_requested || pane.core.output_closed) {
          return;
        }

        pane.body.driver = client.id;
        try {
          if (!std::forward<Request>(request)(pane.body.editor)) {
            return;
          }

          flushEditor(pane);
        } catch (const std::exception&) {
          failEditor(pane);
        }
      }

      // Asks an editor to follow the files the last answered change moved, the `count` that
      // `moves` tells: a buffer that shows one shows it under its new name.
      inline void followMoves(PaneRef<NvimBody> pane, const FileMoves& moves, std::size_t count) noexcept {
        if (pane.core.close_requested || pane.core.output_closed) {
          return;
        }

        try {
          bool asked = false;

          for (std::size_t index = 0; index < count; ++index) {
            const auto move = moves.told(index);

            asked = pane.body.editor.follow(move.from, move.to) || asked;
          }

          if (asked) {
            flushEditor(pane);
          }
        } catch (const std::exception&) {
          failEditor(pane);
        }
      }

      // Stops watching a descriptor of an editor that reached its end, and closes it.
      inline void closeEditorOutput(PaneRef<NvimBody> pane) noexcept {
        poller_.remove(pane.body.process->output());
        pane.body.process.getMut().closeOutput();
      }

      inline void closeEditorErrors(PaneRef<NvimBody> pane) noexcept {
        poller_.remove(pane.body.process->error());
        pane.body.process.getMut().closeError();
      }

      // An editor that cannot go on: what it wrote was refused, or its input broke.
      inline void failEditor(PaneRef<NvimBody> pane) noexcept {
        if (pane.body.process->output() >= 0) {
          closeEditorOutput(pane);
        }

        pane.core.output_closed = true;
        endEditor(pane);
      }

      // Asks an editor's Neovim to leave, as closing its pane does.
      inline void endEditor(PaneRef<NvimBody> pane) noexcept {
        if (pane.body.process->input() >= 0) {
          poller_.remove(pane.body.process->input());
        }

        pane.core.write_interest = false;
        requestClose(pane.core);
      }

      inline tbc::mut_a<Attachment> attach(RuntimeModel& model, tbc::mut_a<ClientSession> client, std::uint64_t pane_id, TerminalSize size) {
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
          resizeTo(pane, size);
        }

        if (auto* existing = client.attachmentMut(pane.id)) {
          return *existing;
        }

        const auto slot = client.availableAttachmentSlot();
        // The attachment shares a terminal's media through its own handle; an editor has none.
        const auto terminal = asTerminal(&pane);
        auto media = !terminal ? decltype(terminal->body.media){} : terminal->body.media;
        const auto clipboard_revision = !terminal ? std::uint64_t{0} : terminal->body.terminal.effects().clipboard_revision;

        auto attachment = ds::makeBox<Attachment>(memory_, memory_, client.graphics_credit, pane.id, std::move(media));

        attachment.getMut().slot = slot;
        attachment.getMut().kind = pane.kind();
        attachment.getMut().graphics.configure(client.shared_graphics);
        attachment.getMut().clipboard_revision = clipboard_revision;

        // The attachment as the client keeps it, once its box is in the client's list.
        auto& result = client.attachments.push(std::move(attachment)).getMut();

        client.workspace = workspace->id;
        pane.observers |= client.observerBit();
        return result;
      }

      // Gives a pane the size its client shows it at, whatever its kind.
      inline void resizeTo(Pane& pane, TerminalSize size) {
        if (const auto terminal = asTerminal(&pane)) {
          telar::runtime::resize(*terminal, size);
        } else if (const auto editor = asNvim(&pane)) {
          telar::runtime::resize(*editor, size);
          flushEditor(*editor);
        } else if (const auto explorer = asExplorer(&pane)) {
          telar::runtime::resize(*explorer, size);
        }
      }

      inline void detach(RuntimeModel& model, ClientStore& clients, AttachmentKey key) noexcept {
        if (!release(model, clients, key)) {
          return;
        }

        if (const auto* client = clients.find(key.client); client != nullptr && client->attachments.empty()) {
          detachAll(model, clients, key.client);
        }
      }

      // Drops a client's attachment to a pane; whether it had one.
      inline bool release(RuntimeModel& model, ClientStore& clients, AttachmentKey key) noexcept {
        const auto identity = key.pane;
        auto* client = clients.find(key.client);
        if (client == nullptr) {
          return false;
        }

        const auto bit = client->observerBit();
        const auto removed = client->attachments.retain([identity](const auto& attachment) {
          return attachment->pane_id != identity;
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
        ds::Array<std::uint64_t, ClientSession::attachment_capacity> detached{};
        std::size_t count = 0;

        for (auto& attachment : client->attachments.viewMut()) {
          attachment.getMut().desktop.reset();
          if (auto* pane = model.panes.find(attachment->pane_id)) {
            pane->observers &= ~bit;
            detached.atMut(count++) = pane->id;
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
          if (client != nullptr && client->attachments.retain([identity](const auto& attachment) {
                return attachment->pane_id != identity;
              }) != 0) {
            pane->observers &= ~client->observerBit();
            released = true;
          }
        }

        if (released) {
          refreshAfterDetach(model, clients, identity);
        }

        // Found again: refreshing borrowed the panes whole. Nothing erased it, so a pane gone here is a
        // broken invariant, which stops the runtime as the throw out of this noexcept function did.
        auto* const found = model.panes.find(identity);
        if (found == nullptr) {
          std::abort();
        }

        visitPaneAs(*found, [&](auto kind) {
          release(kind);
        });

        // A worker may still be reading a terminal's observer and media: each is kept until the
        // worker is done with it.
        if (const auto terminal = asTerminal(found)) { // NOLINT(misc-const-correctness): its observer and media are retired through their shared handles, a mutation tbc sees through the pane
          terminal->body.observer->retiredNextMut() = std::move(model.retired_observers);
          model.retired_observers = terminal->body.observer;
          ++model.retired_observer_count;
          terminal->body.media->retiredNextMut() = std::move(model.retired_media);
          model.retired_media = terminal->body.media;
          ++model.retired_media_count;
        }

        model.panes.erase(identity);
        ++model.pane_revision;
      }

      // Lets go of what a terminal holds outside its pane before the pane is erased: its
      // descriptor, the session its observer records and the transfers its media has under way.
      inline void release(PaneRef<TerminalBody> removed) noexcept {
        poller_.remove(removed.body.process->descriptor());
        if (removed.core.exit_status && !removed.core.exit_observed) {
          removed.body.observer->shellExit(*removed.core.exitCode());
          removed.core.exit_observed = true;
        }

        removed.body.observer->finishSession();
        removed.body.media->cancel();
      }

      // An editor holds only its Neovim's three descriptors outside its pane.
      inline void release(PaneRef<NvimBody> removed) noexcept {
        for (const auto descriptor : {removed.body.process->output(), removed.body.process->error(), removed.body.process->input()}) {
          if (descriptor >= 0) {
            poller_.remove(descriptor);
          }
        }
      }

      // An explorer holds nothing outside its pane.
      inline void release(PaneRef<ExplorerBody> /*removed*/) noexcept {}

      template <typename Observer = IgnorePaneInput>
      inline void input(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PaneInput& request, const Observer& observe = {}) {
        if (const auto* client = clients.find(client_id); client == nullptr || client->attachment(request.pane_id) == nullptr) {
          return;
        }

        auto pane = requireTerminal(model.panes, request.pane_id);
        if (pane.core.output_closed) {
          return;
        }

        if (admitInput(pane, request.bytes.size())) {
          enqueueInput(pane, request.bytes);
          observe(pane.core, request.bytes);
          pane.core.last_input = std::chrono::steady_clock::now();
          flushInput(pane);
        }

        recordInputOrigin(model, clients, {.client = client_id, .pane = request.pane_id});
        ClipboardService::configure(clients, requireTerminal(model.panes, request.pane_id));
      }

      inline static std::size_t typedSize(bool paste, std::span<const Byte> text, std::span<const Byte> enter) noexcept {
        return BracketedPaste::size(text.size(), paste) + enter.size();
      }

      // A line typed at a pane: the prefix and the text, as one paste when `paste`, then `enter`. The
      // prefix ends in a space, so no terminator spans it and the text.
      struct TypedLine {
        bool paste = false;
        std::span<const Byte> prefix;
        std::span<const Byte> text;
        std::span<const Byte> enter;
      };

      template <typename Observer>
      inline static void type(PaneRef<TerminalBody> pane, const TypedLine& line, const Observer& observe) {
        const auto forward = [&](std::span<const Byte> bytes) {
          enqueueInput(pane, bytes);
          observe(pane.core, bytes);
        };

        if (!line.paste) {
          forward(line.prefix);
          forward(line.text);
        } else {
          const auto piece = [&](std::string_view bytes) {
            forward(byteView(bytes));
          };

          piece(BracketedPaste::begin);
          BracketedPaste::body(textView(line.prefix), piece);
          BracketedPaste::body(textView(line.text), piece);
          piece(BracketedPaste::end);
        }

        if (!line.enter.empty()) {
          forward(line.enter);
        }
      }

      // Writes a paste to a pane's input queue, framed when its program asked for bracketed paste.
      inline static void paste(PaneRef<TerminalBody> pane, std::span<const Byte> text, bool bracketed) {
        BracketedPaste::encode(textView(text), bracketed, [&](std::string_view bytes) {
          enqueueInput(pane, byteView(bytes));
        });
      }

      inline bool admitInput(PaneRef<TerminalBody> pane, std::size_t bytes) {
        if (bytes <= TerminalBody::input_limit - pane.body.input.size()) {
          return true;
        }

        TELAR_DIAGNOSTIC(diagnostics::accumulate(pane.body.input_dropped_bytes, bytes));
        limits_.report(LimitReach{.name = "panes.input_queue_capacity", .noun = "queued input bytes", .value = TerminalBody::input_limit, .requested = saturatedAdd(pane.body.input.size(), bytes)});
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

        resizeTo(require(model.panes, request.pane_id), request.size);
      }

      inline void flushInput(PaneRef<TerminalBody> pane) {
        if (pane.core.output_closed) {
          return;
        }

        if (pane.body.media->failed()) {
          failOutput(pane);
          return;
        }

        try {
          pane.body.resumeControl();
          pane.body.write();
          const bool needs_write = pane.body.hasInput();
          if (needs_write != pane.core.write_interest) {
            poller_.writeInterest(pane.body.process->descriptor(), eventToken(EventSource::pane, pane.core.event_identity), needs_write);
            pane.core.write_interest = needs_write;
          }
        } catch (const std::exception&) {
          failOutput(pane);
        }
      }

      inline void failOutput(PaneRef<TerminalBody> pane) noexcept {
        pane.body.terminal.abortControl();
        pane.body.media->cancel();
        requestClose(pane.core);
        pane.core.output_closed = true;
        poller_.remove(pane.body.process->descriptor());
      }

      inline void configureDesktop(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const ConfigurePaneDesktop& request) {
        const auto pane = requireTerminalGeneration(model.panes, request.pane_id, request.pane_generation).core.id;
        auto* client = clients.find(client_id);
        auto* attachment = client == nullptr ? nullptr : client->attachmentMut(pane);
        if (client == nullptr || attachment == nullptr || client->connection.flags().closing) {
          throw RequestError{FailureCode::invalid_request, "Desktop state requires a live pane attachment"};
        }

        if (attachment->desktop == request) {
          return;
        }

        attachment->desktop = request;
        refreshDesktop(model, clients, pane);
        flushInput(requireTerminal(model.panes, pane));
      }

      // A change of only the editor colors leaves the terminals alone: applying colors repaints a
      // pane whole.
      // What the runtime lets a pane's program do with the clipboard, among other things.
      [[nodiscard]] inline const control::Policy& controlPolicy() const noexcept {
        return control_policy_;
      }

      inline void configureColors(RuntimeModel& model, ClientSession& client, const ConfigureTerminalColors& request) {
        const bool repaint = !client.colors.sameTerminalColors(request);

        client.colors = request;
        // An editor shows the syntax and chrome colors too, which a terminal does not.
        for (auto* stored : model.panes.items()) {
          auto editor = asNvim(stored);
          const auto* workspace = !editor ? nullptr : model.workspaces.find(editor->core.location.workspace.id);
          if (workspace != nullptr && workspace->geometry_client == client.id && !editor.getMut().core.close_requested && editor.getMut().body.editor.theme(request)) {
            flushEditor(*editor);
          }
        }

        if (!repaint) {
          return;
        }

        for (auto* stored : model.panes.items()) {
          auto pane = asTerminal(stored);
          const auto* workspace = !pane ? nullptr : model.workspaces.find(pane->core.location.workspace.id);
          if (workspace != nullptr && workspace->geometry_client == client.id && !pane->core.desktop_theme) {
            pane.getMut().body.terminal.configureColors(request);
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

        auto pane = requireTerminal(panes, request.pane_id);
        constexpr std::size_t clipboard_limit = std::size_t{1024} * 1024;
        TextReader reader{memory_, pane.body.terminal, clipboard_limit};

        reader.copy(request);
        if (reader.truncated()) {
          throw RequestError{FailureCode::resource_limit, "Selection exceeds the clipboard limit"};
        }

        client.clipboard.replace(pane.core.id, reader.bytes());
      }

      // A command a client runs at the prompt of a pane it shows. Its text is recorded for the
      // command's history, then typed as a prompt sent with sendText is.
      template <typename Observer = IgnorePaneInput>
      inline void command(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PaneCommand& request, const Observer& observe = {}) {
        if (const auto* client = clients.find(client_id); client == nullptr || client->attachment(request.pane_id) == nullptr) {
          return;
        }

        auto pane = requireTerminal(model.panes, request.pane_id);
        if (pane.core.output_closed) {
          return;
        }

        const bool paste = pane.body.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
        ds::Array<Byte, encoded_key_bytes> encoded_enter{};
        const auto enter = pane.body.terminal.encodeKey(GHOSTTY_KEY_ENTER, 0, encoded_enter.viewMut());
        if (admitInput(pane, typedSize(paste, request.text, enter))) {
          pane.body.submitCommand(request.text);
          type(pane, {.paste = paste, .text = request.text, .enter = enter}, observe);
          pane.core.last_input = std::chrono::steady_clock::now();
          flushInput(pane);
        }

        recordInputOrigin(model, clients, {.client = client_id, .pane = request.pane_id});
        ClipboardService::configure(clients, requireTerminal(model.panes, request.pane_id));
      }

      template <typename Observer = IgnorePaneInput>
      inline void sendText(PaneStore& panes, ClientSession& client, const SendPaneText& request, std::string_view prefix = {}, const Observer& observe = {}) {
        auto pane = requireTerminalGeneration(panes, request.pane_id, request.pane_generation);
        if (pane.core.output_closed) {
          throw RequestError{FailureCode::pane_exited, "Pane process has exited"};
        }

        const auto text = byteView(request.text);
        const bool paste = request.mode == PaneTextMode::prompt && pane.body.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
        ds::Array<Byte, encoded_key_bytes> encoded_enter{};
        const auto enter = request.mode == PaneTextMode::raw ? std::span<const Byte>{} : pane.body.terminal.encodeKey(GHOSTTY_KEY_ENTER, 0, encoded_enter.viewMut());
        const auto required = prefix.size() + typedSize(paste, text, enter);
        if (!admitInput(pane, required)) {
          constexpr std::size_t message_bytes = 160;
          ds::Array<char, message_bytes> message{};
          const auto written = std::format_to_n(message.dataMut(), static_cast<std::ptrdiff_t>(message.size()), "the pane's input queue holds its limit of {} bytes; the program in it is not reading input", TerminalBody::input_limit);
          const auto length = std::min(static_cast<std::size_t>(written.size), message.size());

          client.connection.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::resource_limit, .message = {message.data(), length}});
          return;
        }

        type(pane, {.paste = paste, .prefix = byteView(prefix), .text = text, .enter = enter}, observe);
        if (request.mode != PaneTextMode::raw || request.text.contains('\r')) {
          pane.body.observer->noteInjectedSubmission();
        }

        pane.core.last_input = std::chrono::steady_clock::now();
        flushInput(pane);
        client.connection.send(RequestCompleted{.request_id = request.request_id});
      }

      inline void pasteClipboard(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const PastePaneClipboard& request) {
        auto pane = requireTerminalGeneration(model.panes, request.pane_id, request.pane_generation);
        const auto* client = clients.find(client_id);
        if (client == nullptr || !ClipboardService::eligible(*client, pane) || pane.core.output_closed) {
          throw RequestError{FailureCode::invalid_request, "Clipboard paste requires a live visible attachment"};
        }

        if (request.listing_only) {
          // A listing begun before a mode reset completes without reading text.
          if (pane.body.terminal.pasteEvents()) {
            if (!pane.body.terminal.clipboardControl().paste({.client = client->id, .generation = client->generation}, request.primary, request.available)) {
              throw RequestError{FailureCode::resource_limit, "Clipboard response is pending"};
            }

            pane.body.resumeControl();
          }
        } else if (!request.text.empty()) {
          const bool bracketed = pane.body.terminal.mode(GHOSTTY_MODE_BRACKETED_PASTE);
          if (!admitInput(pane, typedSize(bracketed, request.text, {}))) {
            throw RequestError{FailureCode::resource_limit, "Paste exceeds available pane input capacity"};
          }

          paste(pane, request.text, bracketed);
        }

        recordInputOrigin(model, clients, {.client = client_id, .pane = request.pane_id});
        flushInput(requireTerminal(model.panes, request.pane_id));
        if (auto* current = clients.find(client_id)) {
          current->connection.send(RequestCompleted{.request_id = request.request_id});
        }
      }

      // A search of the whole scrollback, or of some rows of it.
      template <typename Request>
        requires std::same_as<Request, SearchPane> || std::same_as<Request, SearchPaneRows>
      inline static void search(PaneStore& panes, ClientSession& client, const Request& request) {
        const auto pane = requireTerminal(panes, request.pane_id);
        if (client.role == ClientRole::interactive && client.attachment(pane.core.id) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane is not attached"};
        }

        if (client.search) {
          client.connection.send(RequestFailed{.request_id = client.search->requestId(), .code = FailureCode::resource_limit, .message = "Pane search superseded"});
        }

        client.search.emplace(request, pane.body.terminal.contentRevision());
      }

      // The theme a pane's programs read their colors from: that of the client owning its
      // workspace, with the terminal colors a desktop gave the pane in their place. It reads
      // the owner's colors before the asking client is borrowed to send it, as the owner may
      // be that client.
      [[nodiscard]] inline static PaneTheme readTheme(const PaneStore& panes, const ConfigureTerminalColors* owner_colors, const ReadPaneTheme& request) {
        const auto* pane = findPane(panes, {.id = request.pane_id, .generation = request.pane_generation});
        if (pane == nullptr || pane->exit_status) {
          throw RequestError{FailureCode::pane_not_found, "Pane not found"};
        }

        PaneTheme reply{.request_id = request.request_id, .pane_id = pane->id};

        if (owner_colors != nullptr) {
          reply.theme = static_cast<const TerminalTheme&>(*owner_colors);
        }

        if (const auto& desktop = pane->desktop_theme) {
          auto& theme = reply.theme ? reply.theme.getMut() : reply.theme.emplace();

          theme.foreground = desktop->foreground;
          theme.background = desktop->background;
          theme.palette = desktop->palette;
          theme.cursor = desktop->cursor;
        }

        return reply;
      }

      // Rows of an attached pane's scrollback, which its client draws while it scrolls.
      inline static void readRows(PaneStore& panes, ClientSession& client, const ReadPaneRows& request) {
        auto pane = requireTerminal(panes, request.pane_id);
        if (client.attachment(pane.core.id) == nullptr) {
          throw RequestError{FailureCode::pane_not_found, "Pane is not attached"};
        }

        client.connection.send(pane.body.scrollback_rows.read(pane.body.terminal, request));
      }

      inline static bool advanceSearch(PaneStore& panes, ClientSession& client) {
        if (!client.search) {
          return false;
        }

        try {
          const auto pane = requireTerminal(panes, client.search->paneId());
          if (client.search.getMut().advance(pane.body.terminal.handle(), pane.body.terminal.contentRevision())) {
            client.connection.send(client.search.getMut().result());
            client.search.reset();
          }
        } catch (const std::exception&) {
          client.connection.send(RequestFailed{.request_id = client.search->requestId(), .code = FailureCode::resource_limit, .message = "Pane search stopped; retry"});
          client.search.reset();
        }

        return client.search.hasValue();
      }

    private:
      // The client whose input reached a pane.
      struct InputOrigin {
        std::uint64_t client;
        std::uint64_t pane;
      };

      static constexpr std::size_t encoded_key_bytes = 128;

      inline static void recordInputOrigin(RuntimeModel& model, ClientStore& clients, InputOrigin origin) noexcept {
        ++model.input_sequence;
        if (model.input_sequence == 0) {
          for (auto* session : clients.items()) {
            if (session != nullptr) {
              session->last_input_sequence = 0;
            }
          }

          model.input_sequence = 1;
        }

        if (auto* client = clients.find(origin.client)) {
          client->last_input_pane = origin.pane;
          client->last_input_sequence = model.input_sequence;
        }
      }

      // Visibility is the union of explicit live reports. The oldest visible
      // reporter supplies theme facts; focus and the geometry lease cannot steal it.
      inline static void refreshDesktop(RuntimeModel& model, const ClientStore& clients, std::uint64_t identity) {
        auto pane = requireTerminal(model.panes, identity);
        control::ClientFacts facts;
        const ConfigurePaneDesktop* theme = nullptr;
        std::uint64_t theme_client = std::numeric_limits<std::uint64_t>::max();

        for (const auto* client : clients.items()) {
          if (client == nullptr || client->connection.flags().closing) {
            continue;
          }

          const auto* attachment = client->attachment(pane.core.id);
          if (attachment == nullptr || !attachment->desktop || attachment->desktop->pane_generation != pane.core.generation) {
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
          const auto& previous = pane.core.desktop_theme;
          if (!previous || previous->foreground != theme->foreground || previous->background != theme->background || previous->palette != theme->palette || previous->cursor != theme->cursor) {
            pane.body.terminal.configureColors({.foreground = theme->foreground, .background = theme->background, .palette = theme->palette, .cursor = theme->cursor});
          }

          pane.core.desktop_theme = *theme;
        } else if (pane.core.desktop_theme) {
          pane.core.desktop_theme.reset();
          const auto* workspace = model.workspaces.find(pane.core.location.workspace.id);
          const auto* owner = workspace != nullptr && workspace->geometry_client ? clients.find(*workspace->geometry_client) : nullptr;

          pane.body.terminal.configureColors(owner != nullptr && !owner->connection.flags().closing ? owner->colors : ConfigureTerminalColors{});
        }

        pane.body.terminal.configureClientFacts(facts);
        ClipboardService::configure(clients, pane);
      }

      inline static PaneKey allocateIdentity(RuntimeModel& model, std::uint64_t restored_identity = 0) {
        if (model.panes.size() + std::max(model.retired_observer_count, model.retired_media_count) >= pane_capacity) {
          throw RequestError{FailureCode::resource_limit, "Pane capacity is occupied by active processes or pending observations"};
        }

        if (model.next_pane_generation == 0 || model.next_pane_generation == std::numeric_limits<std::uint64_t>::max() || (restored_identity == 0 && model.panes.nextCounter() == 0)) {
          throw RequestError{FailureCode::spawn_failed, "could not start the command"};
        }

        const auto identity = restored_identity == 0 ? model.panes.nextId() : restored_identity;

        model.panes.advanceCounter(identity + 1);
        return {.id = identity, .generation = model.next_pane_generation++};
      }

      // Tells a pane's program which pane it runs in and how to reach this runtime.
      inline void identify(Command<ConcurrentMemory>& command, const RuntimeModel& model, const PanePlacement& placement, PaneKey identity) const {
        constexpr std::size_t identity_text_bytes = 32;
        const auto set_identity = [&](std::string_view name, std::uint64_t value) {
          ds::Array<char, identity_text_bytes> text{};
          const auto converted = std::to_chars(text.dataMut(), text.dataMut() + text.size(), value);

          command.setEnvironment({.name = name, .value = {text.data(), static_cast<std::size_t>(converted.ptr - text.data())}});
        };

        set_identity("TELAR_PANE_ID", identity.id);
        set_identity("TELAR_PANE_GENERATION", identity.generation);
        set_identity("TELAR_WORKSPACE_ID", placement.location.workspace.id);
        set_identity("TELAR_TAB_ID", placement.location.tab_id);
        command.setEnvironment({.name = "TELAR_SOCKET_PATH", .value = socket_path_});
        if (!model.cli_executable.empty()) {
          command.setEnvironment({.name = "TELAR_BIN_PATH", .value = model.cli_executable});
        }
      }

      inline tbc::val_a<PaneRef<TerminalBody>> launchPrepared(tbc::mut_a<RuntimeModel> model, const PanePlacement& placement, Command<ConcurrentMemory>& command, PaneKey identity) {
        identify(command, model, placement, identity);
        // Claude Code keeps its task list tools off for its newest models, and its card's plan comes
        // only from them. A value the user set stays.
        if (agent_plans_ && !command.environment("CLAUDE_CODE_ENABLE_TODO_TOOLS")) {
          command.setEnvironment({.name = "CLAUDE_CODE_ENABLE_TODO_TOOLS", .value = "1"});
        }

        proxy_.apply(command);
        const auto shell = shell_integration_.apply(command, placement.bare_prompt);
        const PaneLaunch settings{.size = placement.size, .media_budget = model.media_budget, .graphics = model.graphics_limits, .shell = shell};
        auto pane = ds::makeBox<Pane>(memory_, memory_, identity.id, placement.location, command, settings);

        pane.getMut().generation = identity.generation;
        const auto* workspace = model.workspaces.find(placement.location.workspace.id);
        const HistorySession session{.id = pane->history_session, .pane = pane->id, .location = placement.location, .started_at_ms = ObservationTime::now().milliseconds, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .shell = command.arguments().front()};

        TELAR_DIAGNOSTIC(std::get<TerminalBody>(pane.getMut().body).counters = &model.metrics.panes);
        std::get<TerminalBody>(pane.getMut().body).terminal.controlPolicy() = control_policy_;
        auto phase = LaunchPhase::pane_registration;
        bool registered = false;

        try {
          if (placement.owner_colors != nullptr) {
            std::get<TerminalBody>(pane.getMut().body).terminal.configureColors(*placement.owner_colors);
          }

          std::get<TerminalBody>(pane->body).observer->configureHistory(session, model.capture_output);
          const auto handle = model.panes.insert(identity.id, std::move(pane));

          registered = true;
          ++model.pane_revision;
          // The pane now lives in the table, where it is found again.
          auto inserted = requireTerminal(model.panes, identity.id);

          inserted.core.event_identity = handle;
          if (handle > maximum_event_identity) {
            throw RequestError{FailureCode::resource_limit, "Pane event identity space exhausted"};
          }

          phase = LaunchPhase::output_actor;
          poller_.watch(inserted.body.process->descriptor(), eventToken(EventSource::pane, handle));
        } catch (const std::exception& error) {
          history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::launch_failed, .session = session, .finished_at_ms = ObservationTime::now().milliseconds, .failure = {.generation = identity.generation, .phase = phase, .cause = launchFailureCause(error)}});
          if (registered) {
            if (const auto failed = asTerminal(model.panes.find(identity.id))) {
              poller_.remove(failed->body.process->descriptor());
            }

            model.panes.erase(identity.id);
            ++model.pane_revision;
          }

          throw;
        }

        return requireTerminal(model.panes, identity.id);
      }

      inline void refreshAfterDetach(RuntimeModel& model, const ClientStore& clients, std::uint64_t identity) noexcept {
        // What a client's leaving changes is a terminal's: who it reports focus and colors for.
        if (!asTerminal(model.panes.find(identity))) {
          return;
        }

        try {
          refreshDesktop(model, clients, identity);
          flushInput(requireTerminal(model.panes, identity));
        } catch (...) {
          if (auto* pane = model.panes.find(identity)) {
            requestClose(*pane);
          }
        }
      }

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::mut_a<Poller> poller_;
      tbc::mut_a<LimitService> limits_;
      tbc::mut_a<History> history_;
      tbc::val_a<std::string_view> socket_path_;
      ProxyClientConfiguration proxy_;
      control::Policy control_policy_;
      tbc::val_a<ShellIntegration<ConcurrentMemory>> shell_integration_;
      bool agent_plans_;
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

      ExecutionService(const ExecutionService&) = delete;
      ExecutionService& operator=(const ExecutionService&) = delete;
      ExecutionService(ExecutionService&&) = delete;
      ExecutionService& operator=(ExecutionService&&) = delete;

      void request(RuntimeModel& model, ClientSession& client, const ExecutionRequest& request);

      void event(const Event& event);

      bool refresh(RuntimeModel& model) noexcept;

      void disconnect(std::uint64_t client_id);

    private:
      [[nodiscard]] Execution<ConcurrentMemory>* find(std::uint64_t identity) const noexcept;

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
