module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <new>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cstdint>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>

#include <poll.h>
#include <dirent.h>
#include <sys/stat.h>

export module telar.runtime.runtime.delivery.client_delivery;

import std;

export import telar.runtime.model.client_layouts;


export import telar.runtime.terminal.text_reader;


export import telar.runtime.editors.remote_editor;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: runtime/clipboard_service.cppm
export {
namespace telar::runtime {

// Desktop clipboard routing between panes and their attached clients.
template <Allocator Memory>
class ClipboardService {
public:
  inline static bool eligible(const ClientSession<Memory> &client, const Pane<Memory> &pane) noexcept {
    const auto *attachment = client.attachment(pane.id);
    return !pane.close_requested && !pane.output_closed && client.role == ClientRole::interactive && !client.connection.closing && attachment != nullptr && attachment->desktop && attachment->desktop->pane_generation == pane.generation && attachment->desktop->visible && attachment->desktop->clipboard;
  }

  inline static void configure(const ClientStore<Memory> &clients, Pane<Memory> &pane) {
    std::array<control::ClipboardRoute, control::ClipboardGrants::capacity> routes;
    std::size_t count = 0;
    const ClientSession<Memory> *preferred = nullptr;
    for (const auto *client : clients.items()) {
      if (client == nullptr || !eligible(*client, pane)) {
        continue;
      }
      if (count == routes.size()) {
        break;
      }
      routes[count++] = {client->id, client->generation};
      if (preferred == nullptr || precedes(*client, *preferred, pane.id)) {
        preferred = client;
      }
    }
    pane.terminal.clipboardControl().routes(std::span{routes}.first(count), preferred != nullptr ? std::optional{control::ClipboardRoute{preferred->id, preferred->generation}} : std::nullopt);
  }

  inline static bool advance(ClientStore<Memory> &clients, Pane<Memory> &pane, std::chrono::steady_clock::time_point now) {
    auto &clipboard = pane.terminal.clipboardControl();
    clipboard.expire(now);
    if (const auto cancellation = clipboard.cancellation()) {
      auto *client = clients.find(cancellation->route.client);
      if (client == nullptr || client->generation != cancellation->route.generation || client->connection.closing) {
        clipboard.cancelled();
      } else {
        try {
          client->connection.send(CancelClipboardDesktop{cancellation->ticket});
          clipboard.cancelled();
        } catch (const ResponseQueueFull &) {
        } catch (const std::bad_alloc &) {
        }
      }
    }
    const auto route = clipboard.route();
    if (route) {
      auto *client = clients.find(route->client);
      if (client == nullptr || client->generation != route->generation || !eligible(*client, pane)) {
        configure(clients, pane);
      } else {
        try {
          if (const auto request = clipboard.request(pane.id, pane.generation)) {
            client->connection.send(*request);
            clipboard.announced();
          } else {
            clipboard.expire(std::chrono::steady_clock::now());
            if (const auto execution = clipboard.execution()) {
              client->connection.send(*execution);
              clipboard.committed();
            }
          }
        } catch (const ResponseQueueFull &) {
          // The owned request survives queue pressure until its deadline.
        } catch (const std::bad_alloc &) {
          // The deadline also bounds retries under the runtime memory budget.
        }
      }
    }
    if (clipboard.hasReply()) {
      pane.terminal.resumeControl();
      return true;
    }
    return false;
  }

  inline static tbc::view<Pane<Memory> *, tbc::lt::a> complete(tbc::view<PaneStore<Memory> &, tbc::lt::a> panes, ClientSession<Memory> &sender, const CompleteClipboardDesktop &completion) {
    auto *pane = panes.find(completion.ticket.pane_id);
    if (pane == nullptr || pane->generation != completion.ticket.pane_generation || sender.generation != completion.ticket.client_generation || !eligible(sender, *pane)) {
      return nullptr;
    }
    pane->terminal.clipboardControl().expire(std::chrono::steady_clock::now());
    if (!pane->terminal.clipboardControl().complete({sender.id, sender.generation}, completion)) {
      return nullptr;
    }
    pane->terminal.resumeControl();
    return pane;
  }

private:
  inline static bool precedes(const ClientSession<Memory> &candidate, const ClientSession<Memory> &current, std::uint64_t pane) noexcept {
    const bool candidate_focus = candidate.attachment(pane)->desktop->focused;
    const bool current_focus = current.attachment(pane)->desktop->focused;
    if (candidate_focus != current_focus) {
      return candidate_focus;
    }
    const auto candidate_input = candidate.last_input_pane == pane ? candidate.last_input_sequence : 0;
    const auto current_input = current.last_input_pane == pane ? current.last_input_sequence : 0;
    return candidate_input != current_input ? candidate_input > current_input : candidate.id < current.id;
  }

};

}
}

// Interface: runtime/delivery/attachment_delivery.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class AttachmentDelivery {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit AttachmentDelivery(RuntimeModel<Memory> &model, ClientSession<Memory> &client) : model_(model), client_(client) {
    for (const auto &attachment : client.attachments) {
      auto *pane = model.panes.find(attachment->pane_id);
      if (pane != nullptr && !attachment->exit_sent) {
        slots_[attachment->slot] = {attachment.get(), pane, false};
        occupied_ |= std::uint64_t{1} << attachment->slot;
      }
    }
  }

  inline bool prepare(DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    const auto start = client_.next_attachment;
    auto candidates = std::rotr(occupied_, static_cast<int>(start));
    while (candidates != 0) {
      const auto slot = (start + std::countr_zero(candidates)) % ClientSession<Memory>::attachment_capacity;
      candidates &= candidates - 1;
      const auto &candidate = slots_[slot];
      auto *attachment = candidate.attachment;
      auto *pane = candidate.pane;
      if (prepare(*attachment, *pane, lane, now, timeout)) {
        client_.next_attachment = (slot + 1) % ClientSession<Memory>::attachment_capacity;
        return true;
      }
    }

    return false;
  }

private:
  struct Slot {
    Attachment<Memory> *attachment;
    Pane<Memory> *pane;
    bool cells_current;
  };

  inline bool prepare(Attachment<Memory> &attachment, Pane<Memory> &pane, DeliveryLane lane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    const auto &effects = pane.terminal.effects;
    switch (lane) {
    case DeliveryLane::cells:
      return cells(attachment, pane, now, timeout);
    case DeliveryLane::cwd:
      return metadata(attachment.cwd_revision, pane.cwd_revision + 1, PaneCwd{pane.id, pane.cwd});
    case DeliveryLane::foreground:
      return metadata(attachment.foreground_revision, pane.foreground_revision, PaneForeground{pane.id, pane.foreground.view()});
    case DeliveryLane::title:
      return metadata(attachment.title_revision, effects.title_revision, PaneTitle{pane.id, effects.title()});
    case DeliveryLane::progress:
      return metadata(attachment.progress_revision, effects.progress_revision, PaneProgress{pane.id, effects.progress_state, effects.progress_percent});
    case DeliveryLane::exit:
      return exit(attachment, pane);
    case DeliveryLane::graphics:
      return graphics(attachment, pane, timeout);
    default:
      return false;
    }
  }

  template <typename Message>
  inline bool metadata(std::uint64_t &observed, std::uint64_t revision, const Message &message) {
    if (observed == revision) {
      return false;
    }

    client_.connection.send(message);
    observed = revision;
    return true;
  }

  inline bool cells(Attachment<Memory> &attachment, Pane<Memory> &pane, Clock::time_point now, std::chrono::nanoseconds &timeout) {
    if (attachment.frames.waitingForAck(pane.terminal.screen)) {
      return false;
    }

    const bool snapshot = attachment.frames.needsSnapshot(pane.terminal.screen);
    if (!snapshot && !pane.terminal.dirty() && attachment.frames.observedRevision() == pane.terminal.screen.revision) {
      slots_[attachment.slot].cells_current = true;
      return false;
    }

    attachment.pacer.configure(client_.frame_interval);
    if (pane.last_input) {
      attachment.pacer.noteInput(*pane.last_input);
    }

    const auto deadline = attachment.pacer.deadline(now);
    if (!snapshot && !pane.output_closed && deadline && now < *deadline) {
      timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(*deadline - now));
      return false;
    }

    if (pane.terminal.mode(GHOSTTY_MODE_SYNC_OUTPUT)) {
      if (pane.sync_started == Clock::time_point{}) {
        pane.sync_started = now;
      }

      const auto release = pane.sync_started + std::chrono::seconds{1};
      if (now < release) {
        timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(release - now));
        return false;
      }
    } else {
      pane.sync_started = {};
    }

    TELAR_TRACE("runtime.publishFrame");
    if (attachment.viewport) {
      pane.terminal.scrollTo(*attachment.viewport);
    }

    pane.terminal.refresh();
    TELAR_DIAGNOSTIC(attachment.frames.setCounters(model_.metrics.frames));
    const auto payload = attachment.frames.prepare(pane.terminal.screen);
    slots_[attachment.slot].cells_current = true;
    if (attachment.viewport) {
      pane.terminal.scrollToBottom();
    }

    if (!snapshot) {
      attachment.pacer.record(now, deadline);
    }
    if (payload.empty()) {
      return false;
    }

    client_.connection.sendPayload(payload);
    return true;
  }

  inline bool exit(Attachment<Memory> &attachment, const Pane<Memory> &pane) {
    if (!pane.output_closed || !pane.exit_status || !pane.media->idle() || attachment.frames.waitingForAck() || !slots_[attachment.slot].cells_current) {
      return false;
    }

    const auto status = *pane.exit_status;
    client_.connection.send(PaneExited{
        .pane_id = pane.id,
        .kind = WIFEXITED(status) ? ExitKind::exited : ExitKind::signaled,
        .value = static_cast<std::uint32_t>(WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status)),
    });
    attachment.exit_sent = true;
    client_.completing_exit = pane.id;
    return true;
  }

  inline bool graphics(Attachment<Memory> &attachment, Pane<Memory> &pane, std::chrono::nanoseconds &timeout) {
    TELAR_DIAGNOSTIC(attachment.graphics.bindCounters(model_.metrics.graphics));
    const auto queued = client_.connection.queuedBytes();
    if (pane.media->busy()) {
      if (attachment.graphics.advanceTransfer(client_.connection)) {
        timeout = std::chrono::nanoseconds::zero();
      }
      return client_.connection.queuedBytes() != queued;
    }

    auto *terminal = pane.media->terminal();
    try {
      const bool pending = terminal == nullptr ? attachment.graphics.publish(client_.connection, pane.terminal.graphics) : attachment.graphics.publish(client_.connection, terminal->graphics);
      if (pending) {
        timeout = std::chrono::nanoseconds::zero();
      }
    } catch (const std::bad_alloc &) {
      attachment.graphics.abandon(terminal == nullptr ? pane.terminal.graphics.revision() : terminal->graphics.revision());
    }
    return client_.connection.queuedBytes() != queued;
  }

  RuntimeModel<Memory> &model_;
  ClientSession<Memory> &client_;
  std::array<Slot, ClientSession<Memory>::attachment_capacity> slots_;
  std::uint64_t occupied_ = 0;
};

template <Allocator Memory>
AttachmentDelivery(RuntimeModel<Memory> &model, ClientSession<Memory> &client) -> AttachmentDelivery<Memory>;

}
}

// Interface: runtime/response_projection.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ResponseProjection {
public:
  inline explicit ResponseProjection(Memory &memory, RuntimeModel<Memory> &model) noexcept : memory_(memory), model_(model) {}

  inline void operator()(const DeferredResponse &response, auto &&send) const {
    TELAR_TRACE("runtime.projectResponse");
    std::visit([&](const auto &request) { project(request, send); }, response);
  }

private:
  inline static bool matchesSnapshot(const Pane<Memory> &pane, TabLocation location) noexcept {
    return !pane.close_requested && !pane.exit_status && pane.location.workspace.kind == location.workspace.kind && pane.location.workspace.id == location.workspace.id && pane.location.tab_id == location.tab_id;
  }

  inline void project(const ReadPane &request, auto &send) const {
    auto *pane = model_.panes.find(request.pane_id);
    if (pane == nullptr || (request.pane_generation != 0 && pane->generation != request.pane_generation)) {
      if (const auto *exited = model_.exited_panes.find(request.pane_id, request.pane_generation)) {
        send(exited->response(request));
      } else {
        send(RequestFailed{.request_id = request.request_id, .code = FailureCode::pane_not_found, .message = "pane closed before its text was read"});
      }
      return;
    }

    constexpr std::size_t maximum_text_bytes = 262144;
    TextReader reader{memory_, pane->terminal, maximum_text_bytes};
    reader.read(request.source, request.rows);
    send(PaneText{.request_id = request.request_id, .pane_id = pane->id, .truncated = reader.truncated(), .text = reader.text(), .exit_code = pane->exitCode()});
  }

  inline void project(const RequestTabSnapshot &request, auto &send) const {
    std::array<PaneDescriptor, 64> descriptors;
    std::size_t count = 0;
    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && matchesSnapshot(*pane, request.location)) {
        descriptors[count++] = PaneDescriptor{.pane_id = pane->id, .lifecycle = PaneLifecycle::running, .pane_generation = pane->generation};
      }
    }

    send(TabSnapshot{.request_id = request.request_id, .location = request.location, .panes = std::span{descriptors}.first(count)});
  }

  inline void project(const RequestWorkspaceSnapshot &request, auto &send) const {
    const auto *workspace = model_.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      send(RequestFailed{.request_id = request.request_id, .code = FailureCode::workspace_not_found, .message = "workspace closed before its snapshot was sent"});
      return;
    }

    std::array<TabDescriptor, 64> descriptors;
    std::array<PaneForeground, 256> foregrounds;
    std::size_t foreground_count = 0;
    std::size_t count = 0;
    for (const auto &tab : workspace->tabs) {
      const auto first = foreground_count;
      const TabLocation location{request.workspace, tab.id};
      for (const auto *pane : model_.panes.items()) {
        if (pane != nullptr && matchesSnapshot(*pane, location)) {
          const auto name = pane->foreground.view();
          foregrounds[foreground_count++] = PaneForeground{pane->id, name.empty() ? "shell" : name};
        }
      }

      const auto names = std::span{foregrounds}.subspan(first, foreground_count - first);
      descriptors[count] = TabDescriptor{.tab_id = tab.id, .position = static_cast<std::uint16_t>(count), .pane_count = static_cast<std::uint16_t>(names.size()), .label = tab.label, .foregrounds = names};
      ++count;
    }

    send(WorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace, .name = workspace->displayName(), .tabs = std::span{descriptors}.first(count)});
  }

  inline void project(const QueryLimits &request, auto &send) const {
    std::array<LimitListEntry, 2 * LimitLedger::capacity> entries;
    std::size_t count = 0;
    for (const auto &row : model_.limits.runtime.rows()) {
      entries[count++] = {row.reach(), LimitOrigin::runtime, row.hits, row.last_ms};
    }

    for (const auto &row : model_.limits.clients.rows()) {
      entries[count++] = {row.reach(), LimitOrigin::client, row.hits, row.last_ms};
    }

    send(LimitList{request.request_id, model_.limits.runtime.evicted(), model_.limits.clients.evicted(), model_.limits.refused_reports, std::span{entries}.first(count)});
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
};

template <Allocator Memory>
ResponseProjection(Memory &memory, RuntimeModel<Memory> &model) -> ResponseProjection<Memory>;

}
}

// Interface: runtime/delivery/client_delivery.cppm
export {
namespace telar::runtime {

template <typename Source, typename Memory>
concept RuntimeStateSource = Allocator<Memory> && requires(Source &source, ClientSession<Memory> &client, const RuntimeModel<Memory> &model, DeliveryLane lane) {
  { source.prepare(client, model, lane) } -> std::same_as<bool>;
};

template <Allocator Memory>
class ClientDelivery {
public:
  using Clock = std::chrono::steady_clock;

  struct Result {
    std::chrono::nanoseconds timeout = std::chrono::nanoseconds::max();
    std::optional<std::uint64_t> detach_pane;
  };

  inline explicit ClientDelivery(Memory &memory, RuntimeModel<Memory> &model) : memory_(memory), model_(model) {}

  template <RuntimeStateSource<Memory> Source>
  inline Result write(ClientSession<Memory> &client, Source &source, Clock::time_point now) {
    TELAR_TRACE("runtime.deliverClient");
    Result result;
    if (!client.connection.writing() && !client.connection.closing) {
      prepare(client, source, now, result.timeout);
    }

    if (!client.connection.hasOutput()) {
      return result;
    }

    client.connection.write(ResponseProjection{memory_, model_});
    if (!client.connection.writing()) {
      result.timeout = std::chrono::nanoseconds::zero();
      result.detach_pane = std::exchange(client.completing_exit, std::nullopt);
    }
    return result;
  }

private:
  template <RuntimeStateSource<Memory> Source>
  inline void prepare(ClientSession<Memory> &client, Source &source, Clock::time_point now, std::chrono::nanoseconds &timeout) {
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
    if (queued_lane <= DeliveryLane::cells || attachments.prepare(DeliveryLane::cells, now, timeout)) {
      return;
    }

    for (const auto lane : {DeliveryLane::agents, DeliveryLane::metrics, DeliveryLane::workspaces}) {
      if (queued_lane <= lane || source.prepare(client, model_, lane)) {
        return;
      }
    }

    for (const auto lane : {DeliveryLane::cwd, DeliveryLane::foreground, DeliveryLane::title, DeliveryLane::progress, DeliveryLane::exit, DeliveryLane::graphics}) {
      if (queued_lane <= lane || attachments.prepare(lane, now, timeout)) {
        return;
      }

      if (lane == DeliveryLane::foreground && foreground(client)) {
        return;
      }
    }
  }

  inline bool resync(ClientSession<Memory> &client) {
    if (!client.workspace_resync) {
      return false;
    }

    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_resyncs));
    auto &change = *client.workspace_resync;
    change.workspace_closed = model_.workspaces.find(change.workspace.id) == nullptr;
    client.connection.send(change);
    client.workspace_resync.reset();
    return true;
  }

  inline bool clipboard(ClientSession<Memory> &client) {
    if (client.clipboard.pending()) {
      client.connection.send(client.clipboard.message());
      client.clipboard.delivered();
      return true;
    }

    for (const auto &attachment : client.attachments) {
      const auto *pane = model_.panes.find(attachment->pane_id);
      if (pane == nullptr || attachment->clipboard_revision == pane->terminal.effects.clipboard_revision) {
        continue;
      }

      client.connection.send(PaneClipboard{pane->id, pane->terminal.effects.clipboard});
      attachment->clipboard_revision = pane->terminal.effects.clipboard_revision;
      return true;
    }
    return false;
  }

  inline bool foreground(ClientSession<Memory> &client) {
    if (!client.subscribed) {
      return false;
    }

    const auto panes = model_.panes.items();
    for (std::size_t slot = 0; slot < panes.size(); ++slot) {
      const auto *pane = panes[slot];
      if (pane == nullptr || pane->exit_status || pane->close_requested || (pane->observers & client.observerBit()) != 0) {
        continue;
      }

      auto &sent = client.foregrounds[slot];
      if (sent.pane != pane->id || sent.revision != pane->foreground_revision) {
        client.connection.send(PaneForeground{pane->id, pane->foreground.view()});
        sent = {pane->id, pane->foreground_revision};
        return true;
      }
    }
    return false;
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
};

template <Allocator Memory>
ClientDelivery(Memory &memory, RuntimeModel<Memory> &model) -> ClientDelivery<Memory>;

}
}

// Interface: runtime/delivery/state_projection.cppm
export {
namespace telar::runtime {

template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
class StateProjection {
public:
  inline explicit StateProjection(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy)
      : workspaces_(workspaces), agents_(agents), metrics_(metrics), layouts_(layouts), proxy_(proxy) {}

  template <Allocator Memory>
    requires requires(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy, const RuntimeModel<Memory> &model, ClientSession<Memory> &client) {
      workspaces.publishList(model, client);
      agents.query(model, client);
      { agents.revision() } -> std::convertible_to<std::uint64_t>;
      metrics.publish(client);
      layouts.publish(model, client);
      { proxy.status() } -> std::convertible_to<ProxyStatus>;
    }
  inline bool prepare(ClientSession<Memory> &client, const RuntimeModel<Memory> &model, DeliveryLane lane) {
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
    default:
      return false;
    }
  }

private:
  Workspaces &workspaces_;
  Agents &agents_;
  Metrics &metrics_;
  Layouts &layouts_;
  const Proxy &proxy_;
};

template <typename Workspaces, typename Agents, typename Metrics, typename Layouts, typename Proxy>
StateProjection(Workspaces &workspaces, Agents &agents, Metrics &metrics, Layouts &layouts, const Proxy &proxy) -> StateProjection<Workspaces, Agents, Metrics, Layouts, Proxy>;

}
}

// Interface: runtime/editor_service.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class EditorService {
public:
  inline explicit EditorService(Memory &memory)
      : editor_(memory) {}

  inline void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    std::array<Byte, 1024> scratch;
    DecodeStorage storage{scratch};
    editor_.open(Codec::decode<OpenEditor>(payload, storage), context, reply);
  }

private:
  RemoteEditor<Memory> editor_;
};

template <ConcurrentAllocator Memory>
EditorService(Memory &memory) -> EditorService<Memory>;

}
}

// Interface: runtime/request_dispatch.cppm
export {
namespace telar::runtime {

template <typename Consumer>
bool dispatchRequest(ClientTag tag, Consumer &&consume) {
  switch (tag) {
  case ClientTag::configure_graphics:
    consume.template operator()<ConfigureGraphics>();
    return true;
  case ClientTag::graphics_credit:
    consume.template operator()<GraphicsCredit>();
    return true;
  case ClientTag::request_graphics_snapshot:
    consume.template operator()<RequestGraphicsSnapshot>();
    return true;
  case ClientTag::open_pane:
    consume.template operator()<OpenPane>();
    return true;
  case ClientTag::create_pane:
    consume.template operator()<CreatePane>();
    return true;
  case ClientTag::close_pane:
    consume.template operator()<ClosePane>();
    return true;
  case ClientTag::pane_input:
    consume.template operator()<PaneInput>();
    return true;
  case ClientTag::pane_resize:
    consume.template operator()<PaneResize>();
    return true;
  case ClientTag::frame_ack:
    consume.template operator()<FrameAck>();
    return true;
  case ClientTag::request_snapshot:
    consume.template operator()<RequestSnapshot>();
    return true;
  case ClientTag::detach_pane:
    consume.template operator()<DetachPane>();
    return true;
  case ClientTag::runtime_stop:
    consume.template operator()<RuntimeStop>();
    return true;
  case ClientTag::request_runtime_state:
    consume.template operator()<RequestRuntimeState>();
    return true;
  case ClientTag::request_tab_snapshot:
    consume.template operator()<RequestTabSnapshot>();
    return true;
  case ClientTag::request_workspace_snapshot:
    consume.template operator()<RequestWorkspaceSnapshot>();
    return true;
  case ClientTag::create_workspace:
    consume.template operator()<CreateWorkspace>();
    return true;
  case ClientTag::rename_workspace:
    consume.template operator()<RenameWorkspace>();
    return true;
  case ClientTag::create_tab:
    consume.template operator()<CreateTab>();
    return true;
  case ClientTag::rename_tab:
    consume.template operator()<RenameTab>();
    return true;
  case ClientTag::close_tab:
    consume.template operator()<CloseTab>();
    return true;
  case ClientTag::hold_tab:
    consume.template operator()<HoldTab>();
    return true;
  case ClientTag::move_tab:
    consume.template operator()<MoveTab>();
    return true;
  case ClientTag::configure_frame_interval:
    consume.template operator()<ConfigureFrameInterval>();
    return true;
  case ClientTag::complete_clipboard_desktop:
    consume.template operator()<CompleteClipboardDesktop>();
    return true;
  case ClientTag::read_runtime_clipboard:
    consume.template operator()<ReadRuntimeClipboard>();
    return true;
  case ClientTag::paste_pane_clipboard:
    consume.template operator()<PastePaneClipboard>();
    return true;
  case ClientTag::configure_pane_desktop:
    consume.template operator()<ConfigurePaneDesktop>();
    return true;
  case ClientTag::configure_terminal_colors:
    consume.template operator()<ConfigureTerminalColors>();
    return true;
  case ClientTag::search_pane:
    consume.template operator()<SearchPane>();
    return true;
  case ClientTag::copy_selection:
    consume.template operator()<CopySelection>();
    return true;
  case ClientTag::read_pane:
    consume.template operator()<ReadPane>();
    return true;
  case ClientTag::send_pane_text:
    consume.template operator()<SendPaneText>();
    return true;
  case ClientTag::set_pane_viewport:
    consume.template operator()<SetPaneViewport>();
    return true;
  case ClientTag::query_clients:
    consume.template operator()<QueryClients>();
    return true;
  case ClientTag::detach_client:
    consume.template operator()<DetachClient>();
    return true;
  case ClientTag::request_client_command:
    consume.template operator()<RequestClientCommand>();
    return true;
  case ClientTag::complete_client_command:
    consume.template operator()<CompleteClientCommand>();
    return true;
  case ClientTag::request_pane_focus:
    consume.template operator()<RequestPaneFocus>();
    return true;
  case ClientTag::complete_pane_focus:
    consume.template operator()<CompletePaneFocus>();
    return true;
  case ClientTag::show_notification:
    consume.template operator()<ShowNotification>();
    return true;
  case ClientTag::update_client_layout:
    consume.template operator()<UpdateClientLayout>();
    return true;
  case ClientTag::query_history:
    consume.template operator()<QueryHistory>();
    return true;
  case ClientTag::import_history:
    consume.template operator()<ImportHistory>();
    return true;
  case ClientTag::delete_history:
    consume.template operator()<DeleteHistory>();
    return true;
  case ClientTag::prune_history:
    consume.template operator()<PruneHistory>();
    return true;
  case ClientTag::read_history_output:
    consume.template operator()<ReadHistoryOutput>();
    return true;
  case ClientTag::history_stats:
    consume.template operator()<HistoryStatsQuery>();
    return true;
  case ClientTag::report_limit:
    consume.template operator()<ReportLimit>();
    return true;
  case ClientTag::query_limits:
    consume.template operator()<QueryLimits>();
    return true;
  case ClientTag::launch_tab:
    consume.template operator()<LaunchTab>();
    return true;
  case ClientTag::register_worktree:
    consume.template operator()<RegisterWorktree>();
    return true;
  case ClientTag::launch_worktree:
    consume.template operator()<LaunchWorktree>();
    return true;
  case ClientTag::forget_worktree:
    consume.template operator()<ForgetWorktree>();
    return true;
  case ClientTag::execution_request:
    consume.template operator()<ExecutionRequest>();
    return true;
  case ClientTag::verify_pane_descent:
    consume.template operator()<VerifyPaneDescent>();
    return true;
  case ClientTag::report_agent:
    consume.template operator()<ReportAgent>();
    return true;
  case ClientTag::report_agent_title:
    consume.template operator()<ReportAgentTitle>();
    return true;
  case ClientTag::report_agent_session:
    consume.template operator()<ReportAgentSession>();
    return true;
  case ClientTag::report_agent_progress:
    consume.template operator()<ReportAgentProgress>();
    return true;
  case ClientTag::interrupt_agent:
    consume.template operator()<InterruptAgent>();
    return true;
  case ClientTag::acknowledge_agent:
    consume.template operator()<AcknowledgeAgent>();
    return true;
  case ClientTag::query_agents:
    consume.template operator()<QueryAgents>();
    return true;
  case ClientTag::report_agent_command:
    consume.template operator()<ReportAgentCommand>();
    return true;
  case ClientTag::find_paths:
    consume.template operator()<FindPaths>();
    return true;
  case ClientTag::open_editor:
    consume.template operator()<OpenEditor>();
    return true;
  case ClientTag::suggest_command:
    consume.template operator()<SuggestCommand>();
    return true;
  default:
    return false;
  }
}

}
}
