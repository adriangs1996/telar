#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <new>
#include <sys/stat.h>
#include <sys/socket.h>
#include <ghostty/vt.h>

import std;
import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.client_peer;
import telar.runtime.model.client_layouts;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.runtime.runtime;

using namespace telar;
using namespace telar::runtime;

namespace {

struct Agents {
  std::uint64_t revision() const { return version; }

  void query(const RuntimeModel<SystemAllocator> &, ClientSession<SystemAllocator> &client) {
    client.connection.send(AgentSnapshot{.revision = version});
    client.agent_revision = version;
    client.agent_workspace_revision = workspace_revision;
  }

  std::uint64_t version = 1;
  std::uint64_t workspace_revision = 1;
};

struct Metrics {
  void publish(ClientSession<SystemAllocator> &) {}
};

struct NoState {
  bool prepare(ClientSession<SystemAllocator> &, const RuntimeModel<SystemAllocator> &, DeliveryLane) { return false; }
};

void clipboardOwnership() {
  SystemAllocator system;
  BudgetAllocator memory{system, 8};
  PendingClipboard clipboard{memory};
  const std::array<Byte, 4> initial{'t', 'e', 'x', 't'};
  clipboard.replace(1, initial);
  try {
    clipboard.replace(2, std::array<Byte, 5>{});
    check(false);
  } catch (const std::bad_alloc &) {
  }
  check(clipboard.pending() && clipboard.message().pane_id == 1);
  check(std::ranges::equal(clipboard.message().bytes, initial));

  clipboard.replace(2, clipboard.message().bytes);
  check(clipboard.message().pane_id == 2 && std::ranges::equal(clipboard.message().bytes, initial));
  clipboard.delivered();
  check(!clipboard.pending());
  clipboard.replace(3, {});
  check(clipboard.pending() && clipboard.message().bytes.empty());

  std::vector<Byte> oversized(PendingClipboard<SystemAllocator>::capacity + 1);
  try {
    clipboard.replace(4, oversized);
    check(false);
  } catch (const EncodingError &) {
  }
  check(clipboard.pending() && clipboard.message().pane_id == 3 && clipboard.message().bytes.empty());
}

void currentState() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/client-delivery.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientLayouts layouts{memory};
  Agents agents;
  Metrics metrics;
  ProxyClientConfiguration proxy;
  StateProjection source{workspaces, agents, metrics, layouts, proxy};
  ClientDelivery delivery{memory, model};
  ClientPeer peer{memory, model, clients, ClientRole::interactive};
  auto &client = peer.session();
  client.subscribed = true;
  client.agent_snapshot_requested = true;
  client.connection.send(RequestCompleted{1});
  const auto now = std::chrono::steady_clock::now();
  delivery.write(client, source, now);
  check(peer.receive<RequestCompleted>().request_id == 1);
  check(!client.layout_sent && !client.proxy_status_sent && client.agent_revision == 0);
  check(client.workspace_revision == 0 && client.agent_snapshot_requested);

  client.clipboard.replace(1, std::array<Byte, 1>{'a'});
  client.clipboard.replace(2, std::array<Byte, 1>{'b'});
  client.workspace_resync = ResyncRequired{.workspace = WorkspaceLocation{.id = 42}};
  delivery.write(client, source, now);
  check(peer.receive<ResyncRequired>().workspace_closed);
  delivery.write(client, source, now);
  const auto clipboard = peer.receive<PaneClipboard>();
  check(clipboard.pane_id == 2 && clipboard.bytes.front() == 'b');
  delivery.write(client, source, now);
  check(!peer.receive<ClientLayoutSnapshot>().restored && client.layout_sent);
  delivery.write(client, source, now);
  check(!peer.receive<ProxyStatus>().active && client.proxy_status_sent);

  agents.version = 9;
  delivery.write(client, source, now);
  check(peer.receive<AgentSnapshot>().revision == 9 && !client.agent_snapshot_requested);
  model.workspace_revision = 7;
  client.agent_workspace_revision = 7;
  delivery.write(client, source, now);
  check(peer.receive<WorkspaceList>().revision == 7);
  check(delivery.write(client, source, now).timeout == std::chrono::nanoseconds::max());

  client.subscribed = false;
  client.agent_snapshot_requested = true;
  delivery.write(client, source, now);
  check(peer.receive<AgentSnapshot>().revision == 9);
  check(!client.agent_snapshot_requested);
}

std::size_t fillSocket(int descriptor) {
  const int capacity = 4096;
  check(::setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) == 0);
  std::array<Byte, 1024> bytes{};
  std::size_t written = 0;
  for (;;) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0) {
      check(errno == EAGAIN || errno == EWOULDBLOCK);
      return written;
    }
    check(count > 0);
    written += count;
  }
}

void drainSocket(int descriptor, std::size_t bytes) {
  std::array<Byte, 1024> buffer;
  while (bytes != 0) {
    const auto count = ::read(descriptor, buffer.data(), std::min(bytes, buffer.size()));
    check(count > 0);
    bytes -= count;
  }
}

void attachmentRotation() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/attachment-delivery.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer peer{memory, model, clients, ClientRole::interactive};
  auto &client = peer.session();
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = launch});
  const auto first = peer.receive<PaneOpened>();
  std::array<std::uint64_t, 3> ids{first.pane_id};
  for (unsigned index = 1; index < ids.size(); ++index) {
    workspaces.createPane(model, panes, clients, client.id, CreatePane{.request_id = index + 1, .location = first.location, .size = {80, 24, 0, 0}, .launch = launch});
    ids[index] = peer.receive<PaneOpened>().pane_id;
  }

  const auto now = std::chrono::steady_clock::now();
  auto timeout = std::chrono::nanoseconds::max();
  client.next_attachment = 1;
  for (const auto index : {1, 2, 0}) {
    AttachmentDelivery delivery{model, client};
    check(delivery.prepare(model, client, DeliveryLane::cells, now, timeout));
    const auto frame = peer.receive<PaneFrame>();
    check(frame.pane_id == ids[index]);
    check(client.attachment(frame.pane_id)->frames.acknowledge(frame.frame_id));
  }

  for (const auto index : {1, 2, 0}) {
    AttachmentDelivery delivery{model, client};
    check(delivery.prepare(model, client, DeliveryLane::cwd, now, timeout));
    check(peer.receive<PaneCwd>().pane_id == ids[index]);
  }

  panes.release(model, clients, client.id, ids[1]);
  auto &reattached = panes.attach(model, client, ids[1], {80, 24, 0, 0});
  check(reattached.slot == 1 && client.next_attachment == 1);
  AttachmentDelivery rotated{model, client};
  check(rotated.prepare(model, client, DeliveryLane::foreground, now, timeout));
  check(peer.receive<PaneForeground>().pane_id == ids[1] && client.next_attachment == 2);
  check(rotated.prepare(model, client, DeliveryLane::cwd, now, timeout));
  check(peer.receive<PaneCwd>().pane_id == ids[1] && client.next_attachment == 2);

  for (auto &attachment : client.attachments) {
    auto &pane = panes.require(model.panes, attachment->pane_id);
    attachment->foreground_revision = pane.foreground_revision;
    pane.terminal.refresh();
    const auto payload = attachment->frames.prepare(pane.terminal.screen);
    if (!payload.empty()) {
      std::vector<Byte> storage(128 * 1024);
      DecodeStorage decoded{storage};
      const auto frame = Codec::decode<PaneFrame>(payload, decoded);
      check(attachment->frames.acknowledge(frame.frame_id));
    }
    attachment->graphics.abandon(0);
  }

  ClientDelivery delivery{memory, model};
  NoState state;
  auto &pane = panes.require(model.panes, ids[0]);
  const auto blocked_bytes = fillSocket(client.connection.descriptor());
  client.connection.send(RequestCompleted{55});
  delivery.write(client, state, now);
  check(client.connection.writing());
  pane.terminal.effects.setProgress(PaneProgressState::set, Byte{20});
  delivery.write(client, state, now);
  pane.terminal.effects.setProgress(PaneProgressState::set, Byte{80});
  delivery.write(client, state, now);
  check(client.attachment(pane.id)->progress_revision == 1);
  drainSocket(peer.descriptor(), blocked_bytes);
  delivery.write(client, state, now);
  check(peer.receive<RequestCompleted>().request_id == 55);
  delivery.write(client, state, now);
  check(peer.receive<PaneProgress>().percent == 80);

  client.attachment(pane.id)->viewport = 0;
  client.attachment(pane.id)->frames.requestSnapshot();
  delivery.write(client, state, now);
  const auto viewport = peer.receive<PaneFrame>();
  check(client.attachment(pane.id)->frames.acknowledge(viewport.frame_id));

  pane.output_closed = true;
  pane.exit_status = 0;
  const auto exit_blocked_bytes = fillSocket(client.connection.descriptor());
  const auto blocked = delivery.write(client, state, now);
  check(!blocked.detach_pane && client.connection.writing() && client.attachment(pane.id)->exit_sent);
  check(!delivery.write(client, state, now).detach_pane);
  drainSocket(peer.descriptor(), exit_blocked_bytes);
  const auto completed = delivery.write(client, state, now);
  check(completed.detach_pane == pane.id && !client.connection.writing());
  check(peer.receive<PaneExited>().pane_id == pane.id);
  check(!delivery.write(client, state, now).detach_pane);
  panes.detachAll(model, clients, client.id);
  for (const auto id : ids) {
    panes.remove(model, clients, id);
  }
}

}

void testClientDelivery() {
  clipboardOwnership();
  currentState();
  attachmentRotation();
}
