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
import telar.runtime.runtime.client_control;
import telar.runtime.runtime.runtime;
#if (TELAR_DIAGNOSTICS)
import telar.runtime.diagnostics.runtime_telemetry;
#endif

using namespace telar;
using namespace telar::runtime;

static void testNotificationCapacity(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  ClientPeer requester{memory, model, clients, ClientRole::interactive};
  ClientPeer observer{memory, model, clients, ClientRole::interactive};
  for (unsigned index = 0; index < 127; ++index) {
    requester.session().connection.send(RequestCompleted{.request_id = index + 1});
  }

  ClientControl<SystemAllocator>::notify(clients, requester.session().id, ShowNotification{.request_id = 128, .notification = NotificationBody{.title = "Capacity", .message = "Reserved"}});
  check(requester.session().connection.responseDepth() == 128);
  check(requester.session().connection.droppedResponses() == 1);
  check(observer.receive<Notification>().message == "Reserved");
  for (unsigned index = 0; index < 127; ++index) {
    check(requester.receive<RequestCompleted>().request_id == index + 1);
  }
  check(requester.receive<NotificationShown>().delivered_clients == 1);

  for (unsigned index = 0; index < 128; ++index) {
    requester.session().connection.send(RequestCompleted{.request_id = index + 1});
  }
  bool refused = false;
  try {
    ClientControl<SystemAllocator>::notify(clients, requester.session().id, ShowNotification{.request_id = 129, .notification = NotificationBody{.title = "Capacity", .message = "Refused"}});
  } catch (const ResponseQueueFull &) {
    refused = true;
  }
  check(refused && !requester.session().connection.closing);
  check(requester.session().connection.responseDepth() == 128);
  check(!observer.session().connection.hasOutput());
}

static void testSaturatedCommandTarget(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  ClientPeer requester{memory, model, clients, ClientRole::control};
  ClientPeer target{memory, model, clients, ClientRole::interactive};
  target.session().identity = 123;
  for (unsigned index = 0; index < 128; ++index) {
    target.session().connection.send(RequestCompleted{.request_id = index + 1});
  }

  RequestClientCommand request;
  request.request_id = 1;
  request.route = ClientRoute{target.session().id, target.session().generation};
  request.action = ClientAction::sidebar_resize;
  request.value = 40;
  bool refused = false;
  try {
    ClientControl<SystemAllocator>::requestCommand(clients, requester.session().id, request);
  } catch (const RequestError &error) {
    refused = error.code() == FailureCode::invalid_request && std::string_view{error.what()} == "ResponseQueueFull";
  }
  check(refused && !target.session().connection.closing);
  check(target.session().connection.responseDepth() == 128);
  check(!requester.session().pending_command);
  limits.report(LimitReach{.name = "runtime.request_capacity", .route = "request"});
  limits.deliver(model, clients);
  check(!target.session().connection.closing && target.session().connection.droppedResponses() == 1);
}

static void testClosureResync(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/response-capacity.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  for (unsigned index = 0; index < 128; ++index) {
    owner.session().connection.send(RequestCompleted{.request_id = index + 1});
  }

  workspaces.closeWorkspace(model, clients, opened.location.workspace.id);
  check(!owner.session().connection.closing);
  check(owner.session().connection.responseDepth() == 128);
  check(owner.session().connection.droppedResponses() == 1);
  check(owner.session().workspace_resync.has_value());
  check(owner.session().workspace_resync->workspace.id == opened.location.workspace.id);
  check(owner.session().workspace_resync->workspace_closed);
#if TELAR_DIAGNOSTICS
  diagnostics::Line sample;
  sample.reset();
  diagnostics::writeRuntimeSample(sample, model, clients);
  const auto text = sample.finish();
  check(text.contains("\"response_queue_depth\":128"));
  check(text.contains("\"response_queue_high_water\":128"));
  check(text.contains("\"response_queue_dropped\":1"));
#endif
  panes.remove(model, clients, opened.pane_id);
}

static void testCommandRouting(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  ClientPeer requester{memory, model, clients, ClientRole::control};
  ClientPeer target{memory, model, clients, ClientRole::interactive};
  ClientPeer impostor{memory, model, clients, ClientRole::interactive};
  target.session().identity = 123;
  impostor.session().identity = 456;

  ClientControl<SystemAllocator>::list(clients, requester.session().id, QueryClients{.request_id = 1});
  const auto list = requester.receive<ClientList>();
  check(list.entries.size() == 2);
  check(list.entries[0].id == target.session().id);
  check(list.entries[0].generation == target.session().generation);

  RequestClientCommand request;
  request.request_id = 2;
  request.route = ClientRoute{target.session().id, target.session().generation};
  request.action = ClientAction::sidebar_resize;
  request.value = 40;
  ClientControl<SystemAllocator>::requestCommand(clients, requester.session().id, request);
  const auto forwarded = target.receive<ClientCommand>();
  check(forwarded.route.id == requester.session().id);
  check(forwarded.value == 40);

  CompleteClientCommand completion;
  static_cast<ClientCommand &>(completion) = forwarded;
  completion.status = ClientCommandStatus::applied;
  ClientControl<SystemAllocator>::completeCommand(clients, impostor.session().id, completion);
  check(requester.session().pending_command.has_value());
  completion.action = ClientAction::sidebar_hide;
  ClientControl<SystemAllocator>::completeCommand(clients, target.session().id, completion);
  check(requester.session().pending_command.has_value());

  completion.action = request.action;
  ClientControl<SystemAllocator>::completeCommand(clients, target.session().id, completion);
  const auto result = requester.receive<ClientCommandResult>();
  check(result.request_id == 2 && result.route.id == target.session().id);
  check(!requester.session().pending_command);

  request.request_id = 3;
  ClientControl<SystemAllocator>::requestCommand(clients, requester.session().id, request);
  target.receive<ClientCommand>();
  ClientControl<SystemAllocator>::abandon(clients, target.session().id);
  check(requester.receive<RequestFailed>().request_id == 3);
  check(!requester.session().pending_command);

  const auto departed = target.session().id;
  clients.erase(departed);
  ClientPeer replacement{memory, model, clients, ClientRole::interactive};
  replacement.session().identity = 789;
  check(replacement.session().id != departed);
  bool rejected = false;
  try {
    ClientControl<SystemAllocator>::requestCommand(clients, requester.session().id, request);
  } catch (const RequestError &) {
    rejected = true;
  }
  check(rejected);

  ClientControl<SystemAllocator>::notify(clients, requester.session().id, ShowNotification{.request_id = 4,
                                                       .notification = NotificationBody{.title = "Build",
                                                                                        .message = "Finished"}});
  check(requester.receive<NotificationShown>().delivered_clients == 2);
  check(replacement.receive<Notification>().message == "Finished");
  check(impostor.receive<Notification>().title == "Build");

  ClientControl<SystemAllocator>::detach(clients, requester.session().id, DetachClient{.request_id = 5,
                                                   .client_id = replacement.session().id,
                                                   .client_generation = replacement.session().generation});
  check(requester.receive<RequestCompleted>().request_id == 5);
  check(replacement.session().connection.closing);
}

static void testFocusAndLayouts(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  ClientLayouts layouts{memory};
  ClientPeer requester{memory, model, clients, ClientRole::control};
  ClientPeer target{memory, model, clients, ClientRole::interactive};
  ClientPeer reconnect{memory, model, clients, ClientRole::interactive};
  target.session().identity = reconnect.session().identity = 123;

  const auto workspace_id = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, workspace_id, "/tmp", "Test");
  workspace->tabs.emplace_back(memory, 1, "Shell");
  const TabLocation location{WorkspaceLocation{.id = workspace_id}, 1};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp",
                                 .arguments = arguments}};
  const auto pane_id = model.panes.nextId();
  auto pane = makeOwned<Pane<SystemAllocator>>(memory, memory, pane_id, location, command, PaneLaunch{TerminalSize{80, 24, 0, 0}, model.media_budget, model.graphics_limits});
  constexpr std::uint64_t pane_generation = 34;
  pane->generation = pane_generation;
  workspace->tabs[0].panes.push_back(pane_id);
  model.workspaces.insert(workspace_id, std::move(workspace));
  model.panes.insert(pane_id, std::move(pane));
  target.session().attachments.push_back(makeOwned<Attachment<SystemAllocator>>(memory, memory, target.session().graphics_credit, pane_id, model.panes.find(pane_id)->media));
  target.session().last_input_pane = pane_id;
  target.session().last_input_sequence = 7;

  ClientControl<SystemAllocator>::requestFocus(model.panes, clients, requester.session().id, RequestPaneFocus{.request_id = 1,
                                                             .pane_id = pane_id,
                                                             .pane_generation = pane_generation,
                                                             .direction = PaneDirection::right});
  const auto forwarded = target.receive<PaneFocusCommand>();
  check(forwarded.requester.id == requester.session().id && forwarded.pane_id == pane_id);
  CompletePaneFocus completion{.requester = forwarded.requester,
                               .request_id = 1,
                               .pane_id = pane_id,
                               .pane_generation = pane_generation + 1,
                               .outcome = PaneFocusOutcome::focused,
                               .focused_pane_id = pane_id};
  ClientControl<SystemAllocator>::completeFocus(clients, target.session().id, completion);
  check(requester.session().pending_focus.has_value());
  completion.pane_generation = pane_generation;
  ClientControl<SystemAllocator>::completeFocus(clients, target.session().id, completion);
  check(requester.receive<PaneFocusResult>().focused_pane_id == pane_id);
  check(requester.session().connection.closing);

  std::array<ClientLayoutNode, 1> nodes{ClientLayoutPane{pane_id}};
  std::array<ClientTabLayout, 1> tabs{ClientTabLayout{.location = location,
                                                      .focused_pane = pane_id,
                                                      .workspace_active = true,
                                                      .nodes = nodes}};
  UpdateClientLayout update{.sidebar_visible = true,
                            .sidebar_width = 35,
                            .active_tab = location,
                            .tabs = tabs};
  update.validate();
  layouts.retain(model, target.session().identity, update);
  check(layouts.focusedPane(target.session().identity) == pane_id);
  nodes[0] = ClientLayoutPane{999};
  layouts.publish(model, reconnect.session());
  const auto restored = reconnect.receive<ClientLayoutSnapshot>();
  check(restored.restored && restored.sidebar_width == 35);
  check(restored.tabs.size() == 1 && std::get<ClientLayoutPane>(restored.tabs[0].nodes[0]).pane_id == pane_id);

  layouts.retain(model, target.session().identity, update);
  layouts.publish(model, reconnect.session());
  check(reconnect.receive<ClientLayoutSnapshot>().tabs.size() == 1);
  model.panes.erase(pane_id);
  model.workspaces.erase(workspace_id);
  layouts.publish(model, reconnect.session());
  const auto pruned = reconnect.receive<ClientLayoutSnapshot>();
  check(pruned.restored && pruned.tabs.empty() && !pruned.active_tab);
}

struct PluginEventsFixture {
  plugins::EffectBatch batch;
  plugins::TapMetrics counters;

  int descriptor() const noexcept { return -1; }
  plugins::TapMetrics metrics() const noexcept { return counters; }

  template <typename Consumer>
  void collect(Consumer &&consumer) {
    consumer(batch);
    batch.count = 0;
  }
};

static void testPluginDelivery(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  PluginDelivery delivery{limits};
  ClientPeer target{memory, model, clients, ClientRole::interactive};
  ClientPeer requester{memory, model, clients, ClientRole::control};
  ClientPeer closing{memory, model, clients, ClientRole::interactive};
  closing.session().connection.closing = true;
  PluginEventsFixture events;

  for (const auto invalid : {NotificationBody{.duration_ms = 499, .title = "invalid"},
                             NotificationBody{.duration_ms = 60001, .title = "invalid"},
                             NotificationBody{.title = ""},
                             NotificationBody{.title = "line\nbreak"},
                             NotificationBody{.title = "\xff"}}) {
    events.batch.count = 1;
    events.batch.notifications[0] = invalid;
    delivery.collect(clients, events);
    check(!target.session().connection.hasOutput());
  }

  NotificationBody notification{.title = "valid"};
  const auto overhead = Codec::encodedSize(Notification{notification});
  const std::string maximum_message(512 - overhead, 'x');
  const std::string oversized_message(maximum_message.size() + 1, 'x');
  events.batch.count = 2;
  events.batch.notifications[0] = NotificationBody{.title = "valid", .message = oversized_message};
  events.batch.notifications[1] = NotificationBody{.title = "valid", .message = maximum_message};
  delivery.collect(clients, events);
  check(target.receive<Notification>().message == maximum_message);
  check(!target.session().connection.hasOutput());
  check(!requester.session().connection.hasOutput() && !closing.session().connection.hasOutput());

  events.counters.dropped_queue = 1;
  delivery.collect(clients, events);
  limits.deliver(model, clients);
  check(target.receive<Notification>().title == "Limit reached");
  delivery.collect(clients, events);
  limits.deliver(model, clients);
  check(!target.session().connection.hasOutput());
  events.counters.dropped_queue = 2;
  delivery.collect(clients, events);
  limits.deliver(model, clients);
  limits.query(requester.session(), QueryLimits{.request_id = 1});
  const auto recorded = requester.receive<LimitList>();
  check(recorded.entries.size() == 1);
  check(recorded.entries[0].reach.name == "plugins.tap.queue_depth" && recorded.entries[0].hits == 2);
}

void testClientControl() {
  SystemAllocator memory;
  testNotificationCapacity(memory);
  testSaturatedCommandTarget(memory);
  testClosureResync(memory);
  testCommandRouting(memory);
  testFocusAndLayouts(memory);
  testPluginDelivery(memory);
}
