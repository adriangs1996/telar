module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.core.delivery.client_delivery;

import std;
import telar.tbc;

import telar.runtime.core.model.client_layouts;

import telar.runtime.workspaces.editors.remote_editor;
import telar.wire.vocabulary;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.editor;
import telar.wire.layout;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.runtime.terminal.control.clipboard;
import telar.runtime.terminal.text_reader;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.core.model.slot_store;
import telar.runtime.nvim.frames;
import telar.runtime.workers.background_executor;
import telar.runtime.transport.connection;
import telar.base.ds;

// Interface: runtime/clipboard_service.cppm
export {
  namespace telar::runtime {

    // Desktop clipboard routing between panes and their attached clients.
    class ClipboardService {
    public:
      static bool eligible(const ClientSession& client, const TerminalPane& pane) noexcept;

      static void configure(const ClientStore& clients, TerminalPane& pane);

      static bool advance(ClientStore& clients, TerminalPane& pane, std::chrono::steady_clock::time_point now);

      static tbc::val_a<TerminalPane*> complete(tbc::mut_a<PaneStore> panes, ClientSession& sender, const CompleteClipboardDesktop& completion);

    private:
      static bool precedes(const ClientSession& candidate, const ClientSession& current, std::uint64_t pane) noexcept;
    };

  }
}

// Interface: runtime/delivery/attachment_delivery.cppm
export {
  namespace telar::runtime {

    // Which of a client's attachments can deliver, found once per write. It keeps the attachments' indexes,
    // not the attachments or their panes, so the client and the model are lent to each call, and the
    // connection apart from the attachment it delivers.
    class AttachmentDelivery {
    public:
      using Clock = std::chrono::steady_clock;

      explicit AttachmentDelivery(const RuntimeModel& model, const ClientSession& client);

      bool prepare(RuntimeModel& model, ClientSession& client, DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds& timeout);

    private:
      struct Slot {
        std::uint8_t index;
        bool cells_current;
      };

      // The parts of the client and the model a delivery writes, lent apart from the attachment and its pane.
      struct Output {
        Connection<ConcurrentMemory>& connection;
        ds::Option<std::uint64_t>& completing_exit;
        std::chrono::nanoseconds frame_interval{};
        [[maybe_unused]] diagnostics::RuntimeCounters& metrics;
        NvimFrames& editor_frames;
        Clock::time_point now;
        std::chrono::nanoseconds& timeout;
      };

      bool prepare(Output& output, Attachment& attachment, TerminalPane& pane, DeliveryLane lane);

      // An editor's lanes: its frames, and what every pane says of its program.
      bool prepare(Output& output, Attachment& attachment, NvimPane& pane, DeliveryLane lane);

      // What the client lacks of an editor's screen, as the grids of one frame and its end.
      bool editorFrame(Output& output, Attachment& attachment, const NvimPane& pane);

      template <typename Message>
      static bool metadata(Connection<ConcurrentMemory>& connection, std::uint64_t& observed, std::uint64_t revision, const Message& message);

      // The pane's document, one chunk per delivery; a newer revision restarts from its start, so
      // a client never assembles parts of two documents.
      static bool document(Connection<ConcurrentMemory>& connection, Attachment& attachment, const TerminalPane& pane);

      // The documents that stand for rows of the pane's scrollback: one a client has that the pane
      // let go of is withdrawn first, then each one's parts go in order, then rows that moved.
      static bool inlineDocuments(Connection<ConcurrentMemory>& connection, Attachment& attachment, const TerminalPane& pane);

      static bool blocks(Connection<ConcurrentMemory>& connection, Attachment& attachment, const TerminalPane& pane);

      // How the scrollback numbers its rows, before a frame numbered so. A viewport held above the
      // bottom keeps showing the same rows when the scrollback drops rows above them.
      static bool scrollback(Connection<ConcurrentMemory>& connection, Attachment& attachment, TerminalPane& pane);

      bool cells(Output& output, Attachment& attachment, TerminalPane& pane, Clock::time_point now, std::chrono::nanoseconds& timeout);

      // What something in the editor asks the user, or that it stopped asking, told once.
      static bool editorPrompt(Connection<ConcurrentMemory>& connection, Attachment& attachment, const NvimPane& pane);

      // Tells the client its pane ended, once it was `delivered` all the pane had to show.
      bool exit(Output& output, Attachment& attachment, const Pane& pane, bool delivered);

      static bool graphics(Output& output, Attachment& attachment, TerminalPane& pane, std::chrono::nanoseconds& timeout);

      static bool publishGraphics(Connection<ConcurrentMemory>& connection, Attachment& attachment, TerminalPane& pane, std::chrono::nanoseconds& timeout);

      ds::Array<Slot, ClientSession::attachment_capacity> slots_;
      std::uint64_t occupied_ = 0;
    };

  }
}

// Interface: runtime/response_projection.cppm
export {
  namespace telar::runtime {

    class ResponseProjection {
    public:
      explicit ResponseProjection(ConcurrentMemory& memory, RuntimeModel& model) noexcept;

      // Kept here: `send` is the connection's callable, an open set no unit can instantiate ahead.
      // Reading a pane's text moves its terminal, so projecting is a Rust `FnMut`, not an `Fn`.
      TBC_GENERIC inline void operator()(const DeferredResponse& response, auto&& send) {
        TELAR_TRACE("runtime.projectResponse");
        std::visit([&](const auto& request) {
          project(request, send);
        },
            response);
      }

    private:
      static bool matchesSnapshot(const Pane& pane, TabLocation location) noexcept;

      // A pane's output decodes its OSC 7 directory, so it can hold a NUL the codec rejects;
      // one such pane must not fail the snapshot of its whole workspace.
      [[nodiscard]] static std::string_view snapshotDirectory(std::string_view cwd) noexcept;

      // Kept here: `send` is the connection's callable, an open set no unit can instantiate ahead.
      TBC_GENERIC inline void project(const ReadPane& request, auto& send) {
        // Generation 0 reads whatever generation the pane has, as clients that predate generations ask.
        auto* pane = request.pane_generation == 0 ? model_.panes.find(request.pane_id) : findPane(model_.panes, {.id = request.pane_id, .generation = request.pane_generation});
        if (pane == nullptr) {
          if (const auto* exited = model_.exited_panes.find(request.pane_id, request.pane_generation)) {
            send(exited->response(request));
          } else {
            send(RequestFailed{.request_id = request.request_id, .code = FailureCode::pane_not_found, .message = "pane closed before its text was read"});
          }

          return;
        }

        auto* terminal = pane->asMut<TerminalPane>();
        if (terminal == nullptr) {
          send(RequestFailed{.request_id = request.request_id, .code = FailureCode::unsupported_pane_kind, .message = "This pane is not a terminal"});
          return;
        }

        constexpr std::size_t maximum_text_bytes = 262144;
        // Read before the reader borrows the pane's terminal for as long as its text is sent.
        const auto pane_id = terminal->id;
        const auto exit_code = terminal->exitCode();
        TextReader reader{memory_, terminal->terminal, maximum_text_bytes};

        reader.read(request.source, request.rows);
        send(PaneText{.request_id = request.request_id, .pane_id = pane_id, .truncated = reader.truncated(), .text = reader.text(), .exit_code = exit_code});
      }

      // Kept here: `send` is the connection's callable, an open set no unit can instantiate ahead.
      TBC_GENERIC inline void project(const RequestTabSnapshot& request, auto& send) {
        ds::Array<PaneDescriptor, max_snapshot_tab_panes> descriptors;
        std::size_t count = 0;

        for (const auto* pane : model_.panes.items()) {
          if (pane != nullptr && matchesSnapshot(*pane, request.location)) {
            descriptors.atMut(count++) = PaneDescriptor{.pane_id = pane->id, .lifecycle = PaneLifecycle::running, .pane_generation = pane->generation};
          }
        }

        // A pane that is not a terminal says so before the snapshot names it.
        for (const auto* pane : model_.panes.items()) {
          if (pane != nullptr && pane->kind != PaneKind::terminal && matchesSnapshot(*pane, request.location)) {
            send(PaneKindNotice{.pane_id = pane->id, .kind = pane->kind});
          }
        }

        send(TabSnapshot{.request_id = request.request_id, .location = request.location, .panes = std::span{descriptors}.first(count)});
      }

      // Kept here: `send` is the connection's callable, an open set no unit can instantiate ahead.
      TBC_GENERIC inline void project(const RequestWorkspaceSnapshot& request, auto& send) {
        const auto* workspace = model_.workspaces.find(request.workspace.id);
        if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
          send(RequestFailed{.request_id = request.request_id, .code = FailureCode::workspace_not_found, .message = "workspace closed before its snapshot was sent"});
          return;
        }

        ds::Array<TabDescriptor, max_snapshot_workspace_tabs> descriptors;
        ds::Array<TabPane, PaneStore::capacity> panes;
        // Where each tab's panes start: they are lent to the descriptors only once every pane is written.
        ds::Array<std::size_t, max_snapshot_workspace_tabs> firsts{};
        std::size_t pane_count = 0;
        std::size_t count = 0;

        for (const auto& tab : workspace->tabs) {
          const auto first = pane_count;
          const TabLocation location{.workspace = request.workspace, .tab_id = tab.id};

          for (const auto* pane : model_.panes.items()) {
            if (pane != nullptr && matchesSnapshot(*pane, location)) {
              const auto name = pane->foreground.view();

              panes.atMut(pane_count++) = TabPane{.pane_id = pane->id, .foreground = name.empty() ? "shell" : name, .cwd = snapshotDirectory(pane->cwd)};
            }
          }

          firsts.atMut(count) = first;
          descriptors.atMut(count) = TabDescriptor{.tab_id = tab.id, .position = static_cast<std::uint16_t>(count), .pane_count = static_cast<std::uint16_t>(pane_count - first), .label = tab.label};
          ++count;
        }

        for (std::size_t index = 0; index < count; ++index) {
          descriptors.atMut(index).panes = std::span{panes}.subspan(firsts[index], descriptors[index].pane_count);
        }

        send(WorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace, .name = workspace->displayName(), .tabs = std::span{descriptors}.first(count)});
      }

      // Kept here: `send` is the connection's callable, an open set no unit can instantiate ahead.
      TBC_GENERIC inline void project(const QueryLimits& request, auto& send) {
        ds::Array<LimitListEntry, 2 * LimitLedger::capacity> entries;
        std::size_t count = 0;

        for (const auto& row : model_.limits.runtime.rows()) {
          entries.atMut(count++) = {.reach = row.reach(), .origin = LimitOrigin::runtime, .hits = row.hits, .last_ms = row.last_ms};
        }

        for (const auto& row : model_.limits.clients.rows()) {
          entries.atMut(count++) = {.reach = row.reach(), .origin = LimitOrigin::client, .hits = row.hits, .last_ms = row.last_ms};
        }

        send(LimitList{.request_id = request.request_id, .runtime_evicted = model_.limits.runtime.evicted(), .client_evicted = model_.limits.clients.evicted(), .refused_reports = model_.limits.refused_reports, .entries = std::span{entries}.first(count)});
      }

      ConcurrentMemory& memory_;
      RuntimeModel& model_;
    };

  }
}

// Interface: runtime/delivery/client_delivery.cppm
export {
  namespace telar::runtime {

    template <typename Source>
    concept RuntimeStateSource = requires(Source& source, ClientSession& client, const RuntimeModel& model, DeliveryLane lane) {
      { source.prepare(client, model, lane) } -> std::same_as<bool>;
    };

    class ClientDelivery {
    public:
      using Clock = std::chrono::steady_clock;

      struct Result {
        std::chrono::nanoseconds timeout = std::chrono::nanoseconds::max();
        ds::Option<std::uint64_t> detach_pane;
      };

      explicit ClientDelivery(ConcurrentMemory& memory, RuntimeModel& model);

      // Kept here: the source is the runtime's StateProjection over its own services, or a test's fake.
      template <RuntimeStateSource Source>
      TBC_GENERIC inline Result write(ClientSession& client, Source& source, Clock::time_point now) {
        TELAR_TRACE("runtime.deliverClient");
        Result result;

        if (!client.connection.writing() && !client.connection.flags().closing) {
          prepare(client, source, now, result.timeout);
        }

        if (!client.connection.hasOutput()) {
          return result;
        }

        client.connection.write(ResponseProjection{memory_, model_});
        if (!client.connection.writing()) {
          result.timeout = std::chrono::nanoseconds::zero();
          result.detach_pane = std::exchange(client.completing_exit, ds::none);
        }

        return result;
      }

    private:
      // Kept here: the source is the runtime's StateProjection over its own services, or a test's fake.
      template <RuntimeStateSource Source>
      TBC_GENERIC inline void prepare(ClientSession& client, Source& source, Clock::time_point now, std::chrono::nanoseconds& timeout) {
        const auto queued_lane = client.connection.nextLane();
        if (queued_lane <= DeliveryLane::management) {
          return;
        }

        if (resync(client) || clipboard(client)) {
          return;
        }

        for (const auto lane : {DeliveryLane::layout, DeliveryLane::proxy}) {
          if (queued_lane <= lane || source.prepare(client, model_, lane)) {
            return;
          }
        }

        AttachmentDelivery attachments{model_, client};

        for (const auto lane : {DeliveryLane::shell, DeliveryLane::scrollback, DeliveryLane::cells}) {
          if (queued_lane <= lane || attachments.prepare(model_, client, lane, now, timeout)) {
            return;
          }
        }

        for (const auto lane : {DeliveryLane::agents, DeliveryLane::metrics, DeliveryLane::workspaces}) {
          if (queued_lane <= lane || source.prepare(client, model_, lane)) {
            return;
          }
        }

        if (queued_lane <= DeliveryLane::panes || paneList(client, now)) {
          return;
        }

        for (const auto lane : {DeliveryLane::cwd, DeliveryLane::foreground, DeliveryLane::title, DeliveryLane::progress, DeliveryLane::git, DeliveryLane::blocks, DeliveryLane::exit, DeliveryLane::graphics, DeliveryLane::document}) {
          if (queued_lane <= lane || attachments.prepare(model_, client, lane, now, timeout)) {
            return;
          }

          if (lane == DeliveryLane::foreground && foreground(client)) {
            return;
          }
        }
      }

      bool resync(ClientSession& client);

      bool clipboard(ClientSession& client);

      bool paneList(ClientSession& client, Clock::time_point now);

      bool foreground(ClientSession& client);

      ConcurrentMemory& memory_;
      RuntimeModel& model_;
    };

  }
}

// Interface: runtime/delivery/state_projection.cppm
export {
  namespace telar::runtime {

    // Kept whole: tests instantiate it with their own fake services (client_delivery_test's Agents and Metrics).
    template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
    class TBC_GENERIC StateProjection {
    public:
      inline explicit StateProjection(Workspaces& workspaces, Agents& agents, Metrics& metrics, Layouts& layouts, const Proxy& proxy)
          : workspaces_(workspaces),
            agents_(agents),
            metrics_(metrics),
            layouts_(layouts),
            proxy_(proxy) {}

      inline bool prepare(ClientSession& client, const RuntimeModel& model, DeliveryLane lane)
        requires requires(Workspaces& workspaces, Agents& agents, Metrics& metrics, Layouts& layouts, const Proxy& proxy) {
          workspaces.publishList(model, client);
          agents.query(model, client);
          { agents.revision() } -> std::convertible_to<std::uint64_t>;
          metrics.publish(client);
          layouts.publish(model, client);
          { proxy.status() } -> std::convertible_to<ProxyStatus>;
        }
      {
        switch (lane) {
        case DeliveryLane::layout:
          if (client.subscribed && !client.layout_sent) {
            layouts_.publish(model, client);
            client.layout_sent = true;
            return true;
          }

          return false;
        case DeliveryLane::proxy:
          if (client.subscribed && !client.proxy_status_sent) {
            client.connection.send(proxy_.status());
            client.proxy_status_sent = true;
            return true;
          }

          return false;
        case DeliveryLane::agents:
          if (client.agent_snapshot_requested || (client.subscribed && (client.agent_revision != agents_.revision() || client.agent_workspace_revision != model.workspace_revision))) {
            agents_.query(model, client);
            client.agent_snapshot_requested = false;
            return true;
          }

          return false;
        case DeliveryLane::metrics: {
          const auto queued = client.connection.queuedBytes();

          metrics_.publish(client);
          return queued != client.connection.queuedBytes();
        }
        case DeliveryLane::workspaces:
          if (client.subscribed && client.workspace_revision != model.workspace_revision) {
            workspaces_.publishList(model, client);
            return true;
          }

          return false;
        case DeliveryLane::stopping:
        case DeliveryLane::management:
        case DeliveryLane::resync:
        case DeliveryLane::clipboard:
        case DeliveryLane::shell:
        case DeliveryLane::scrollback:
        case DeliveryLane::cells:
        case DeliveryLane::panes:
        case DeliveryLane::cwd:
        case DeliveryLane::foreground:
        case DeliveryLane::title:
        case DeliveryLane::progress:
        case DeliveryLane::git:
        case DeliveryLane::blocks:
        case DeliveryLane::exit:
        case DeliveryLane::graphics:
        case DeliveryLane::document:
        case DeliveryLane::observation:
        case DeliveryLane::count:
          return false;
        }

        // A lane outside the enum projects nothing, as the lanes the runtime's state does not own.
        return false;
      }

    private:
      Workspaces& workspaces_;
      Agents& agents_;
      Metrics& metrics_;
      Layouts& layouts_;
      const Proxy& proxy_;
    };

    template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
    StateProjection(Workspaces& workspaces, Agents& agents, Metrics& metrics, Layouts& layouts, const Proxy& proxy) -> StateProjection<Workspaces, Agents, Metrics, Layouts, Proxy>;

  }
}

// Interface: runtime/editor_service.cppm
export {
  namespace telar::runtime {

    class EditorService {
    public:
      explicit EditorService(ConcurrentMemory& memory);

      void process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context = {});

    private:
      RemoteEditor editor_;
    };

  }
}

// Interface: runtime/request_dispatch.cppm
export {
  namespace telar::runtime {

    // Kept here: the consumer is the caller's callable, an open set no unit can instantiate ahead.
    template <typename Consumer>
    TBC_GENERIC bool dispatchRequest(ClientTag tag, Consumer&& consume) {
      return ClientRequests::dispatch(tag, std::forward<Consumer>(consume));
    }

  }
}
