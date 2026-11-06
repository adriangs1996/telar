#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#if (TELAR_DIAGNOSTICS)
#endif

#include "client_peer.hpp"
#include "../diagnostics/line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <array>
#include <span>
#include <sys/types.h>
#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <optional>
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
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
#if (defined(__linux__))
#endif
#include <new>
#include "telar_config/terminal/control/policy.hpp"
#include <sys/stat.h>
#if (TELAR_DIAGNOSTICS)
#endif

#if TELAR_DIAGNOSTICS
#endif

#if (TELAR_DIAGNOSTICS)
#endif

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
  ClientControl control{model};
  ClientPeer requester{memory, model, ClientRole::interactive};
  ClientPeer observer{memory, model, ClientRole::interactive};
  for (unsigned index = 0; index < 127; ++index) {
    requester.session().connection.send(RequestCompleted{.request_id = index + 1});
  }

  control.notify(requester.session(), ShowNotification{.request_id = 128, .notification = NotificationBody{.title = "Capacity", .message = "Reserved"}});
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
    control.notify(requester.session(), ShowNotification{.request_id = 129, .notification = NotificationBody{.title = "Capacity", .message = "Refused"}});
  } catch (const ResponseQueueFull &) {
    refused = true;
  }
  check(refused && !requester.session().connection.closing);
  check(requester.session().connection.responseDepth() == 128);
  check(!observer.session().connection.hasOutput());
}

static void testSaturatedCommandTarget(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientControl control{model};
  ClientPeer requester{memory, model, ClientRole::control};
  ClientPeer target{memory, model, ClientRole::interactive};
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
    control.requestCommand(requester.session(), request);
  } catch (const RequestError &error) {
    refused = error.code() == FailureCode::invalid_request && std::string_view{error.what()} == "ResponseQueueFull";
  }
  check(refused && !target.session().connection.closing);
  check(target.session().connection.responseDepth() == 128);
  check(!requester.session().pending_command);

  LimitService limits{model};
  limits.report(LimitReach{.name = "runtime.request_capacity", .route = "request"});
  check(!target.session().connection.closing && target.session().connection.droppedResponses() == 1);
}

static void testClosureResync(SystemAllocator &memory) {
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/response-capacity.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  for (unsigned index = 0; index < 128; ++index) {
    owner.session().connection.send(RequestCompleted{.request_id = index + 1});
  }

  workspaces.closeWorkspace(opened.location.workspace.id);
  check(!owner.session().connection.closing);
  check(owner.session().connection.responseDepth() == 128);
  check(owner.session().connection.droppedResponses() == 1);
  check(owner.session().workspace_resync.has_value());
  check(owner.session().workspace_resync->workspace.id == opened.location.workspace.id);
  check(owner.session().workspace_resync->workspace_closed);
#if TELAR_DIAGNOSTICS
  diagnostics::Line sample;
  sample.reset();
  diagnostics::writeRuntimeSample(sample, model);
  const auto text = sample.finish();
  check(text.contains("\"response_queue_depth\":128"));
  check(text.contains("\"response_queue_high_water\":128"));
  check(text.contains("\"response_queue_dropped\":1"));
#endif
  panes.remove(opened.pane_id);
}

static void testCommandRouting(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientControl control{model};
  ClientPeer requester{memory, model, ClientRole::control};
  ClientPeer target{memory, model, ClientRole::interactive};
  ClientPeer impostor{memory, model, ClientRole::interactive};
  target.session().identity = 123;
  impostor.session().identity = 456;

  control.list(requester.session(), QueryClients{.request_id = 1});
  const auto list = requester.receive<ClientList>();
  check(list.entries.size() == 2);
  check(list.entries[0].id == target.session().id);
  check(list.entries[0].generation == target.session().generation);

  RequestClientCommand request;
  request.request_id = 2;
  request.route = ClientRoute{target.session().id, target.session().generation};
  request.action = ClientAction::sidebar_resize;
  request.value = 40;
  control.requestCommand(requester.session(), request);
  const auto forwarded = target.receive<ClientCommand>();
  check(forwarded.route.id == requester.session().id);
  check(forwarded.value == 40);

  CompleteClientCommand completion;
  static_cast<ClientCommand &>(completion) = forwarded;
  completion.status = ClientCommandStatus::applied;
  control.completeCommand(impostor.session(), completion);
  check(requester.session().pending_command.has_value());
  completion.action = ClientAction::sidebar_hide;
  control.completeCommand(target.session(), completion);
  check(requester.session().pending_command.has_value());

  completion.action = request.action;
  control.completeCommand(target.session(), completion);
  const auto result = requester.receive<ClientCommandResult>();
  check(result.request_id == 2 && result.route.id == target.session().id);
  check(!requester.session().pending_command);

  request.request_id = 3;
  control.requestCommand(requester.session(), request);
  target.receive<ClientCommand>();
  control.abandon(target.session().id);
  check(requester.receive<RequestFailed>().request_id == 3);
  check(!requester.session().pending_command);

  const auto departed = target.session().id;
  model.clients.erase(departed);
  ClientPeer replacement{memory, model, ClientRole::interactive};
  replacement.session().identity = 789;
  check(replacement.session().id != departed);
  bool rejected = false;
  try {
    control.requestCommand(requester.session(), request);
  } catch (const RequestError &) {
    rejected = true;
  }
  check(rejected);

  control.notify(requester.session(), ShowNotification{.request_id = 4,
                                                       .notification = NotificationBody{.title = "Build",
                                                                                        .message = "Finished"}});
  check(requester.receive<NotificationShown>().delivered_clients == 2);
  check(replacement.receive<Notification>().message == "Finished");
  check(impostor.receive<Notification>().title == "Build");

  control.detach(requester.session(), DetachClient{.request_id = 5,
                                                   .client_id = replacement.session().id,
                                                   .client_generation = replacement.session().generation});
  check(requester.receive<RequestCompleted>().request_id == 5);
  check(replacement.session().connection.closing);
}

static void testFocusAndLayouts(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientControl control{model};
  ClientLayouts layouts{memory, model};
  ClientPeer requester{memory, model, ClientRole::control};
  ClientPeer target{memory, model, ClientRole::interactive};
  ClientPeer reconnect{memory, model, ClientRole::interactive};
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

  control.requestFocus(requester.session(), RequestPaneFocus{.request_id = 1,
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
  control.completeFocus(target.session(), completion);
  check(requester.session().pending_focus.has_value());
  completion.pane_generation = pane_generation;
  control.completeFocus(target.session(), completion);
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
  layouts.retain(target.session().identity, update);
  check(layouts.focusedPane(target.session().identity) == pane_id);
  nodes[0] = ClientLayoutPane{999};
  layouts.publish(reconnect.session());
  const auto restored = reconnect.receive<ClientLayoutSnapshot>();
  check(restored.restored && restored.sidebar_width == 35);
  check(restored.tabs.size() == 1 && std::get<ClientLayoutPane>(restored.tabs[0].nodes[0]).pane_id == pane_id);

  layouts.retain(target.session().identity, update);
  layouts.publish(reconnect.session());
  check(reconnect.receive<ClientLayoutSnapshot>().tabs.size() == 1);
  model.panes.erase(pane_id);
  model.workspaces.erase(workspace_id);
  layouts.publish(reconnect.session());
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
  ClientControl control{model};
  LimitService limits{model};
  PluginDelivery delivery{control, limits};
  ClientPeer target{memory, model, ClientRole::interactive};
  ClientPeer requester{memory, model, ClientRole::control};
  ClientPeer closing{memory, model, ClientRole::interactive};
  closing.session().connection.closing = true;
  PluginEventsFixture events;

  for (const auto invalid : {NotificationBody{.duration_ms = 499, .title = "invalid"},
                             NotificationBody{.duration_ms = 60001, .title = "invalid"},
                             NotificationBody{.title = ""},
                             NotificationBody{.title = "line\nbreak"},
                             NotificationBody{.title = "\xff"}}) {
    events.batch.count = 1;
    events.batch.notifications[0] = invalid;
    delivery.collect(events);
    check(!target.session().connection.hasOutput());
  }

  NotificationBody notification{.title = "valid"};
  const auto overhead = Codec::encodedSize(Notification{notification});
  const std::string maximum_message(512 - overhead, 'x');
  const std::string oversized_message(maximum_message.size() + 1, 'x');
  events.batch.count = 2;
  events.batch.notifications[0] = NotificationBody{.title = "valid", .message = oversized_message};
  events.batch.notifications[1] = NotificationBody{.title = "valid", .message = maximum_message};
  delivery.collect(events);
  check(target.receive<Notification>().message == maximum_message);
  check(!target.session().connection.hasOutput());
  check(!requester.session().connection.hasOutput() && !closing.session().connection.hasOutput());

  events.counters.dropped_queue = 1;
  delivery.collect(events);
  check(target.receive<Notification>().title == "Limit reached");
  delivery.collect(events);
  check(!target.session().connection.hasOutput());
  events.counters.dropped_queue = 2;
  delivery.collect(events);
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
