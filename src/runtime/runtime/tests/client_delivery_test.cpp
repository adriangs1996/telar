#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
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
#include <ghostty/vt.h>
#include <new>
#include <sys/socket.h>
#include <sys/stat.h>

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.base.text.utf8;
import telar.platform.primitives;
import telar.render.document;
import telar.runtime.terminal.control;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.model.client_layouts;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.runtime.runtime;
import telar.runtime.graphics.synchronizer;
import telar.runtime.platform.request_worker;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.model.slot_store;
import telar.runtime.platform.event_loop;
import telar.runtime.proxy.runtime;
import telar.runtime.runtime.execution_service;
import telar.runtime.terminal.ghostty;
import telar.runtime.transport.connection;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  namespace {

    struct Agents {
      std::uint64_t revision() const {
        return version;
      }

      void query(const RuntimeModel&, ClientSession& client) {
        client.connection.send(AgentSnapshot{.revision = version});
        client.agent_revision = version;
        client.agent_workspace_revision = workspace_revision;
      }

      std::uint64_t version = 1;
      std::uint64_t workspace_revision = 1;
    };

    struct Metrics {
      void publish(ClientSession&) {}
    };

    struct NoState {
      bool prepare(ClientSession&, const RuntimeModel&, DeliveryLane) {
        return false;
      }
    };

    void clipboardOwnership() {
      SystemAllocator system;
      BudgetAllocator budget{system, 8};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
      PendingClipboard clipboard{memory};
      const ds::Array<Byte, 4> initial{'t', 'e', 'x', 't'};

      clipboard.replace(1, initial);
      try {
        clipboard.replace(2, ds::Array<Byte, 5>{});
        check(false);
      } catch (const std::bad_alloc&) {
      }

      check(clipboard.pending() && clipboard.message().pane_id == 1);
      check(std::ranges::equal(clipboard.message().bytes, initial));

      clipboard.replace(2, clipboard.message().bytes);
      check(clipboard.message().pane_id == 2 && std::ranges::equal(clipboard.message().bytes, initial));
      clipboard.delivered();
      check(!clipboard.pending());
      clipboard.replace(3, {});
      check(clipboard.pending() && clipboard.message().bytes.empty());

      std::vector<Byte> oversized(PendingClipboard::capacity + 1);

      try {
        clipboard.replace(4, oversized);
        check(false);
      } catch (const EncodingError&) {
      }

      check(clipboard.pending() && clipboard.message().pane_id == 3 && clipboard.message().bytes.empty());
    }

    void currentState() {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/client-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientLayouts layouts{memory};
      Agents agents;
      Metrics metrics;
      ProxyClientConfiguration proxy;
      StateProjection source{workspaces, agents, metrics, layouts, proxy};
      ClientDelivery delivery{memory, model};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();

      client.subscribed = true;
      client.agent_snapshot_requested = true;
      client.connection.send(RequestCompleted{1});
      const auto now = std::chrono::steady_clock::now();

      delivery.write(client, source, now);
      check(peer.receive<RequestCompleted>().request_id == 1);

      client.clipboard.replace(1, ds::Array<Byte, 1>{'a'});
      client.clipboard.replace(2, ds::Array<Byte, 1>{'b'});
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
      delivery.write(client, source, now);
      const auto listed = peer.receive<PaneList>();

      check(listed.revision == model.pane_revision + model.workspace_revision && listed.entries.empty());
      check(client.pane_revision == model.pane_revision && client.pane_workspace_revision == model.workspace_revision);
      check(delivery.write(client, source, now).timeout == std::chrono::nanoseconds::max());
      ++model.pane_revision;
      delivery.write(client, source, now);
      check(peer.receive<PaneList>().revision == model.pane_revision + model.workspace_revision);

      client.subscribed = false;
      client.agent_snapshot_requested = true;
      delivery.write(client, source, now);
      check(peer.receive<AgentSnapshot>().revision == 9);
      check(!client.agent_snapshot_requested);
    }

    std::size_t fillSocket(int descriptor) {
      const int capacity = 4096;

      check(::setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) == 0);
      ds::Array<Byte, 1024> bytes{};
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
      ds::Array<Byte, 1024> buffer;

      while (bytes != 0) {
        const auto count = ::read(descriptor, buffer.dataMut(), std::min(bytes, buffer.size()));

        check(count > 0);
        bytes -= count;
      }
    }

    // An integrated shell's state goes to each attachment once per change, ahead of its cells;
    // other panes never send one.
    void shellState() {
      static_assert(DeliveryLane::shell < DeliveryLane::cells);
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/shell-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};

      workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
      auto& pane = panes.require(model.panes, peer.receive<PaneOpened>().pane_id);
      const auto now = std::chrono::steady_clock::now();
      auto timeout = std::chrono::nanoseconds::max();

      check(!AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::shell, now, timeout));

      pane.shell_state.shell = IntegratedShell::zsh;
      pane.shell_state.phase = ShellPhase::prompt;
      ++pane.shell_revision;
      check(AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::shell, now, timeout));
      const auto state = peer.receive<PaneShell>();

      check(state.pane_id == pane.id && state.shell == IntegratedShell::zsh && state.phase == ShellPhase::prompt);
      check(!AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::shell, now, timeout));
    }

    // How the scrollback numbers its rows reaches each attachment once per change, ahead of its
    // cells; a viewport above the bottom moves up with the rows the scrollback dropped.
    void scrollbackOrigin() {
      static_assert(DeliveryLane::scrollback < DeliveryLane::cells);
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/scrollback-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};

      workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {40, 5, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
      auto& pane = panes.require(model.panes, peer.receive<PaneOpened>().pane_id);
      const auto now = std::chrono::steady_clock::now();
      auto timeout = std::chrono::nanoseconds::max();

      check(AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::scrollback, now, timeout));
      const auto first = peer.receive<PaneScrollback>();

      check(first.pane_id == pane.id && first.generation == pane.terminal.scrollbackGeneration() && first.trimmed == 0);
      check(!AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::scrollback, now, timeout));

      const std::size_t limit = 1;

      checkGhostty(ghostty_terminal_set(pane.terminal.handle(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit));
      pane.terminal.followScrollback();
      client.attachmentMut(pane.id)->viewport = 50'000;
      std::string lines;

      for (std::size_t line = 0; line < 8; ++line) {
        lines += "scrollback line\r\n";
      }

      for (std::size_t batch = 0; batch < 4000 && pane.terminal.scrollbackTrimmed() == 0; ++batch) {
        pane.terminal.feed({reinterpret_cast<const Byte*>(lines.data()), lines.size()}, *pane.media);
        pane.terminal.followScrollback();
      }

      const auto trimmed = pane.terminal.scrollbackTrimmed();

      check(trimmed > 0);
      check(AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::scrollback, now, timeout));
      const auto dropped = peer.receive<PaneScrollback>();

      check(dropped.trimmed == trimmed && dropped.generation == first.generation);
      check(client.attachmentMut(pane.id)->viewport == 50'000 - trimmed);
      panes.detachAll(model, clients, client.id);
      panes.remove(model, clients, pane.id);
    }

    // A program on the alternate screen hands its pane a document: it reaches the client in
    // chunks, and is withdrawn once the program leaves the alternate screen. On the primary screen
    // the same sequence is ignored, so ordinary output cannot take a pane over.
    void paneDocument() {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/document-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};

      workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {40, 5, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
      auto& pane = panes.require(model.panes, peer.receive<PaneOpened>().pane_id);
      const auto now = std::chrono::steady_clock::now();
      auto timeout = std::chrono::nanoseconds::max();
      const auto deliver = [&] {
        return AttachmentDelivery{model, client}.prepare(model, client, DeliveryLane::document, now, timeout);
      };

      // Reads as the pane's read loop does: no more than the media worker holds at once.
      MediaProcessor processor;
      ObservationWorker<decltype(processor)&> worker{std::in_place, processor};
      const auto feed = [&](std::string_view bytes) {
        while (!bytes.empty()) {
          const auto take = std::min(bytes.size(), Pane::read_buffer_size);

          while (pane.media->holdsRead(take)) {
            check(pane.media->seal());
            MediaProcessor::Request request;

            request.entries.atMut(request.count++).media = pane.media;
            check(worker.submit(request));
            worker.wait([&](const auto&) {
              pane.media->complete();
            });
          }

          pane.terminal.feed({reinterpret_cast<const Byte*>(bytes.data()), take}, *pane.media);
          bytes.remove_prefix(take);
        }

        pane.terminal.refresh();
      };

      check(!deliver());

      std::vector<Byte> document(PaneDocument::chunk_bytes + 100);

      for (std::size_t index = 0; index < document.size(); ++index) {
        document[index] = static_cast<Byte>(index * 7);
      }

      std::string sequence = "\x1b]7780;begin;";
      const auto body = sequence.size();

      sequence.resize(body + (document.size() + 2) / 3 * 4);
      check(base64::encode(document, std::span<char>{sequence}.subspan(body)).hasValue());
      sequence += "\x1b\\";

      // On the primary screen a sequence alone opens a zone no end closed: nothing shows.
      feed(sequence);
      check(pane.terminal.effects().document.empty() && pane.terminal.effects().inline_documents.empty() && !deliver());

      feed("\x1b[?1049h");
      feed(sequence);
      check(deliver());
      {
        const auto first = peer.receive<PaneDocument>();

        check(first.pane_id == pane.id && first.size == document.size() && first.offset == 0 && first.bytes.size() == PaneDocument::chunk_bytes);
        check(std::ranges::equal(first.bytes, std::span{document}.first(PaneDocument::chunk_bytes)));
      }

      check(deliver());
      const auto revision = [&] {
        const auto rest = peer.receive<PaneDocument>();

        check(rest.offset == PaneDocument::chunk_bytes && std::ranges::equal(rest.bytes, std::span{document}.subspan(PaneDocument::chunk_bytes)));
        return rest.revision;
      }();

      check(!deliver());
      // Nothing of the sequence reached the screen.
      check(pane.terminal.outputSettled());

      feed("\x1b[?1049l");
      check(pane.terminal.effects().document.empty());
      check(deliver());
      const auto closed = peer.receive<PaneDocument>();

      check(closed.size == 0 && closed.bytes.empty() && closed.revision > revision);
      check(!deliver());

      // On the primary screen, the rows between the sequences that begin and end a document are
      // the zone it stands for, numbered as the scrollback numbers them.
      const std::string small = "\x1b]7780;begin;AAECAw==\x1b\\";

      feed("\r\n" + small + "first\r\nsecond\r\n\x1b]7780;end\x1b\\");
      check(pane.terminal.effects().inline_documents.size() == 1);
      check(deliver());
      const auto zone = peer.receive<PaneDocument>();

      check(zone.id != 0 && zone.rows == 2 && zone.size == 4 && zone.offset == 0 && zone.bytes.size() == 4);
      check(zone.generation == pane.terminal.scrollbackGeneration() && zone.first_row == pane.terminal.scrollbackTrimmed() + pane.terminal.effects().inline_documents.front().row);
      check(!deliver());

      // A reflow numbers the rows anew: the client hears where the rows went, without the bytes.
      pane.terminal.resize({30, 5, 0, 0}, *pane.media);
      pane.terminal.refresh();
      check(deliver());
      const auto moved = peer.receive<PaneDocument>();

      check(moved.id == zone.id && moved.generation != zone.generation && moved.offset == moved.size && moved.bytes.empty() && moved.rows >= 2);
      check(!deliver());

      // Past the pane's limit the oldest document goes, and its client hears so first.
      for (std::size_t index = 0; index < ::telar::render::max_pane_documents; ++index) {
        feed(small + "more\r\n\x1b]7780;end\x1b\\");
      }

      check(pane.terminal.effects().inline_documents.size() == ::telar::render::max_pane_documents);
      check(deliver());
      const auto withdrawn = peer.receive<PaneDocument>();

      check(withdrawn.id == zone.id && withdrawn.size == 0);

      // A document stands for the text its rows held: erasing that text lets the document go.
      const auto kept = pane.terminal.effects().inline_documents.size();

      feed("\x1b[H\x1b[2J");
      check(pane.terminal.effects().inline_documents.size() < kept);
      panes.detachAll(model, clients, client.id);
      panes.remove(model, clients, pane.id);
    }

    void attachmentRotation() {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/attachment-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
      const Launch launch{.cwd = "/tmp", .arguments = arguments};

      workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = launch});
      const auto first = peer.receive<PaneOpened>();
      ds::Array<std::uint64_t, 3> ids{first.pane_id};

      for (unsigned index = 1; index < ids.size(); ++index) {
        workspaces.createPane(model, panes, clients, client.id, CreatePane{.request_id = index + 1, .location = first.location, .size = {80, 24, 0, 0}, .launch = launch});
        ids.atMut(index) = peer.receive<PaneOpened>().pane_id;
      }

      const auto now = std::chrono::steady_clock::now();
      auto timeout = std::chrono::nanoseconds::max();

      client.next_attachment = 1;
      for (const auto index : {1, 2, 0}) {
        AttachmentDelivery delivery{model, client};

        check(delivery.prepare(model, client, DeliveryLane::cells, now, timeout));
        const auto frame = peer.receive<PaneFrame>();

        check(frame.pane_id == ids[index]);
        check(client.attachmentMut(frame.pane_id)->frames.acknowledge(frame.frame_id));
      }

      for (const auto index : {1, 2, 0}) {
        AttachmentDelivery delivery{model, client};

        check(delivery.prepare(model, client, DeliveryLane::cwd, now, timeout));
        check(peer.receive<PaneCwd>().pane_id == ids[index]);
      }

      panes.release(model, clients, {.client = client.id, .pane = ids[1]});
      auto& reattached = panes.attach(model, client, ids[1], {80, 24, 0, 0});

      check(reattached.slot == 1 && client.next_attachment == 1);
      AttachmentDelivery rotated{model, client};

      check(rotated.prepare(model, client, DeliveryLane::foreground, now, timeout));
      check(peer.receive<PaneForeground>().pane_id == ids[1] && client.next_attachment == 2);
      check(rotated.prepare(model, client, DeliveryLane::cwd, now, timeout));
      check(peer.receive<PaneCwd>().pane_id == ids[1] && client.next_attachment == 2);

      for (auto& attachment : client.attachments.viewMut()) {
        auto& pane = panes.require(model.panes, attachment->pane_id);

        attachment.getMut().foreground_revision = pane.foreground_revision;
        attachment.getMut().scrollback_generation = pane.terminal.scrollbackGeneration();
        attachment.getMut().scrollback_trimmed = pane.terminal.scrollbackTrimmed();
        pane.terminal.refresh();
        const auto payload = attachment.getMut().frames.prepare(pane.terminal.screen());
        if (!payload.empty()) {
          std::vector<Byte> storage(128 * 1024);
          DecodeStorage decoded{storage};
          const auto frame = Codec::decode<PaneFrame>(payload, decoded);

          check(attachment.getMut().frames.acknowledge(frame.frame_id));
        }

        attachment.getMut().graphics.abandon(0);
      }

      ClientDelivery delivery{memory, model};
      NoState state;
      auto& pane = panes.require(model.panes, ids[0]);
      const auto blocked_bytes = fillSocket(client.connection.descriptor());

      client.connection.send(RequestCompleted{55});
      delivery.write(client, state, now);
      check(client.connection.writing());
      pane.terminal.effectsMut().setProgress(PaneProgressState::set, Byte{20});
      delivery.write(client, state, now);
      pane.terminal.effectsMut().setProgress(PaneProgressState::set, Byte{80});
      delivery.write(client, state, now);
      check(client.attachment(pane.id)->progress_revision == 1);
      drainSocket(peer.descriptor(), blocked_bytes);
      delivery.write(client, state, now);
      check(peer.receive<RequestCompleted>().request_id == 55);
      delivery.write(client, state, now);
      check(peer.receive<PaneProgress>().percent == 80);

      client.attachmentMut(pane.id)->viewport = 0;
      client.attachmentMut(pane.id)->frames.requestSnapshot();
      delivery.write(client, state, now);
      const auto viewport = peer.receive<PaneFrame>();

      check(client.attachmentMut(pane.id)->frames.acknowledge(viewport.frame_id));

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

    // A program that begins a synchronized update and never ends it still gets its screen drawn.
    void syncOutputReleased() {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/sync-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer peer{memory, model, clients, ClientRole::interactive};
      auto& client = peer.session();
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};

      workspaces.open(model, panes, clients, client.id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
      const auto opened = peer.receive<PaneOpened>();
      auto& pane = panes.require(model.panes, opened.pane_id);
      auto timeout = std::chrono::nanoseconds::max();
      const auto start = std::chrono::steady_clock::now() + std::chrono::minutes{1};
      const auto frame = [&](std::chrono::steady_clock::time_point now) {
        AttachmentDelivery delivery{model, client};

        if (!delivery.prepare(model, client, DeliveryLane::cells, now, timeout)) {
          return false;
        }

        check(client.attachmentMut(pane.id)->frames.acknowledge(peer.receive<PaneFrame>().frame_id));
        return true;
      };

      frame(start);
      constexpr std::string_view update = "\x1b[?2026hhalf-drawn";

      pane.terminal.feed({reinterpret_cast<const Byte*>(update.data()), update.size()}, *pane.media);
      check(!frame(start + std::chrono::milliseconds{100}), "a frame went out in the middle of a synchronized update");
      check(frame(start + std::chrono::seconds{2}), "a synchronized update that never ends held the screen back");
    }

    // More workspace changes than the runtime queues between deliveries: every client that watches a
    // changed workspace still resynchronizes it, though its change was not queued.
    void noticeOverflowResyncsObservers() {
      telar::testing::TestMemory adapter;
      ConcurrentMemory& memory = adapter;
      RuntimeModel model{memory};
      ClientStore clients{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/notice-delivery.sock"}};
      WorkspaceService<decltype(poller)> workspaces{memory};
      ClientPeer owner{memory, model, clients, ClientRole::interactive};
      ClientPeer observer{memory, model, clients, ClientRole::interactive};
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
      const Launch launch{.cwd = "/tmp", .arguments = arguments};

      workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = launch});
      const auto busy = owner.receive<PaneOpened>().location.workspace;

      workspaces.createWorkspace(model, panes, clients, observer.session().id, CreateWorkspace{.request_id = 2, .size = {80, 24, 0, 0}, .name = "Watched", .launch = launch});
      const auto watched = observer.receive<PaneOpened>().location.workspace;

      for (std::uint64_t request = 3; request < 1003; ++request) {
        workspaces.renameWorkspace(model, owner.session(), RenameWorkspace{.request_id = request, .workspace = busy, .name = "Busy"});
        owner.receive<WorkspaceSnapshot>();
      }

      workspaces.renameWorkspace(model, owner.session(), RenameWorkspace{.request_id = 1003, .workspace = watched, .name = "Renamed"});
      owner.receive<WorkspaceSnapshot>();
      workspaces.deliverNotices(clients);
      ClientDelivery delivery{memory, model};
      NoState state;

      delivery.write(observer.session(), state, std::chrono::steady_clock::now());
      check(observer.receive<ResyncRequired>().workspace.id == watched.id, "the watched workspace's change was lost");
    }

  }

  void testClientDelivery() {
    clipboardOwnership();
    currentState();
    attachmentRotation();
    shellState();
    scrollbackOrigin();
    paneDocument();
  }

  const telar::testing::Case case_client_delivery{"client_delivery.client_delivery", testClientDelivery};
  const telar::testing::Case case_sync_output_released{"client_delivery.sync_output_released_after_one_second", syncOutputReleased};
  const telar::testing::Case case_notice_overflow_resyncs_observers{"client_delivery.notice_overflow_resyncs_observers", noticeOverflowResyncsObservers};

}
