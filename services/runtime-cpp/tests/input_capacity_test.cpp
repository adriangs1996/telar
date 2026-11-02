#include "client_peer.hpp"
#if TELAR_DIAGNOSTICS
#include "diagnostics/runtime_sample.hpp"
#endif
#include "runtime/workspace_service.hpp"

using namespace telar;
using namespace telar::runtime;

void testInputCapacity() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/input-capacity.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer control{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  const std::vector<Byte> retained(Pane<SystemAllocator>::input_limit, 'a');
  pane.input.append(retained);
  const auto revision = pane.input_revision;
  unsigned observations = 0;
  const auto observe = [&](const auto &, std::span<const Byte>) { ++observations; };
  const std::array<Byte, 3> rejected{'b', 'a', 'd'};
  panes.input(owner.session(), PaneInput{pane.id, rejected}, observe);
  check(owner.receive<Notification>().message == "panes.input_queue_capacity: 131075 queued input bytes; limit 131072");
  check(pane.input.readable().size() == retained.size() && std::equal(retained.begin(), retained.end(), pane.input.readable().begin()));
  check(pane.input_revision == revision && observations == 0 && !pane.last_input);
  check(owner.session().last_input_pane == pane.id && owner.session().last_input_sequence == 1);

  constexpr std::string_view paste_mode = "\x1b[?2004h";
  pane.terminal.feed({reinterpret_cast<const Byte *>(paste_mode.data()), paste_mode.size()});
  panes.sendText(control.session(), SendPaneText{.request_id = 2, .pane_id = pane.id, .mode = PaneTextMode::prompt, .text = "new"}, {}, observe);
  const auto failure = control.receive<RequestFailed>();
  check(failure.request_id == 2 && failure.code == FailureCode::resource_limit);
  check(failure.message == "the pane's input queue holds its limit of 131072 bytes; the program in it is not reading input");
  check(pane.input_revision == revision && observations == 0 && pane.input.size() == retained.size());

  LimitService{model}.query(control.session(), QueryLimits{.request_id = 3});
  const auto limits = control.receive<LimitList>();
  check(limits.entries.size() == 1 && limits.entries.front().hits == 2);
  check(limits.entries.front().reach.name == "panes.input_queue_capacity");
  check(limits.entries.front().reach.requested == retained.size() + 16);
#if TELAR_DIAGNOSTICS
  check(pane.input_dropped_bytes == 19);
  diagnostics::Line sample;
  sample.reset();
  diagnostics::writeRuntimeSample(sample, model);
  check(sample.finish().contains("\"pane_input_dropped_bytes\":19"));
  pane.input_dropped_bytes = std::numeric_limits<std::uint64_t>::max() - 1;
#endif

  control.session().last_input_sequence = 7;
  model.input_sequence = std::numeric_limits<std::uint64_t>::max();
  panes.input(owner.session(), PaneInput{pane.id, rejected}, observe);
  check(model.input_sequence == 1 && owner.session().last_input_sequence == 1);
  check(control.session().last_input_sequence == 0 && observations == 0);
#if TELAR_DIAGNOSTICS
  check(pane.input_dropped_bytes == std::numeric_limits<std::uint64_t>::max());
#endif

  pane.input.truncate(retained.size() - rejected.size());
  panes.input(owner.session(), PaneInput{pane.id, rejected}, observe);
  check(pane.input_revision == revision + 1 && observations == 1 && pane.last_input);
  check(owner.session().last_input_sequence == 2);
  panes.remove(pane.id);
}
