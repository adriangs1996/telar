#include "backpressure.hpp"
#include <poll.h>
#include <termios.h>

using namespace telar;

static int child() {
  termios settings;
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  constexpr std::string_view ready = "ready";
  check(::write(STDOUT_FILENO, ready.data(), ready.size()) == static_cast<ssize_t>(ready.size()));
  std::array<char, 4096> bytes;
  for (;;) {
    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    if (count <= 0) {
      return 0;
    }
    check(::write(STDOUT_FILENO, bytes.data(), count) == count);
  }
}

static void settle(ProtocolPeer &peer) {
  pollfd ready{.fd = peer.descriptor(), .events = POLLIN, .revents = 0};
  while (::poll(&ready, 1, 100) > 0) {
    peer.receivePayload();
  }
}

static void current(const char *socket, const char *executable, const char *dump_path) {
  ProtocolPeer owner{socket};
  owner.send(RequestRuntimeState{101, true});
  owner.receive<WorkspaceList>();
  ProtocolPeer slow{socket, false};
  slow.send(RequestRuntimeState{102, true});
  slow.receive<WorkspaceList>();
  ProtocolPeer control{socket};
  const std::array<std::string_view, 2> arguments{executable, "--child"};
  const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  waitForText(control, opened.pane_id, "ready");
  slow.exchange<PaneOpened>(OpenPane{.request_id = 2, .target = PaneTarget{.kind = PaneTarget::Kind::pane, .id = opened.pane_id}, .size = {80, 24, 0, 0}});
  settle(slow);
  blockOutput(slow, owner, control);

  for (unsigned index = 1; index <= 4; ++index) {
    const auto value = "Value" + std::to_string(index);
    const auto title = "Title" + std::to_string(index);
    const auto output = "\x1b]2;" + title + "\x1b\\\x1b]9;4;1;" + std::to_string(index * 20) + "\x1b\\\x1b[2J\x1b[H" + value;
    control.exchange<RequestCompleted>(SendPaneText{.request_id = 30, .pane_id = opened.pane_id, .mode = PaneTextMode::raw, .text = output});
    waitForText(control, opened.pane_id, value);
    check(owner.receive<PaneTitle>().title == title);
    owner.exchange<WorkspaceSnapshot>(RenameWorkspace{40, opened.location.workspace, "Workspace" + std::to_string(index)});
    slow.send(CopySelection{.pane_id = opened.pane_id, .end_x = 5});
    slow.send(QueryAgents{50});
    barrier(slow, owner);
  }

  std::ofstream output{dump_path, std::ios::binary};
  std::vector<Byte> storage(512 * 1024);
  unsigned received = 0;
  while (received != 31) {
    const auto payload = slow.receivePayload();
    DecodeStorage decoded{storage};
    switch (static_cast<ServerTag>(payload.front())) {
    case ServerTag::pane_clipboard: {
      const auto message = Codec::decode<PaneClipboard>(payload, decoded);
      check(std::string_view{reinterpret_cast<const char *>(message.bytes.data()), message.bytes.size()} == "Value4");
      slow.record(output, message);
      check((received & 1) == 0);
      received |= 1;
      break;
    }
    case ServerTag::agent_snapshot: {
      auto message = Codec::decode<AgentSnapshot>(payload, decoded);
      check(message.entries.empty() && (received & 16) == 0);
      message.revision = 1;
      slow.record(output, message);
      received |= 16;
      break;
    }
    case ServerTag::workspace_list: {
      auto message = Codec::decode<WorkspaceList>(payload, decoded);
      check(message.entries.size() == 1 && message.entries.front().name == "Workspace4");
      message.revision = 1;
      slow.record(output, message);
      check((received & 2) == 0);
      received |= 2;
      break;
    }
    case ServerTag::pane_title: {
      const auto message = Codec::decode<PaneTitle>(payload, decoded);
      check(message.title == "Title4");
      slow.record(output, message);
      check((received & 4) == 0);
      received |= 4;
      break;
    }
    case ServerTag::pane_progress: {
      const auto message = Codec::decode<PaneProgress>(payload, decoded);
      check(message.state == PaneProgressState::set && message.percent == 80);
      slow.record(output, message);
      check((received & 8) == 0);
      received |= 8;
      break;
    }
    default:
      break;
    }
  }
  check(slow.exchange<ClientList>(QueryClients{90}).entries.size() == 2);
  check(output.good());
}

static void rotation(const char *socket, const char *executable, const char *dump_path) {
  ProtocolPeer owner{socket};
  owner.send(RequestRuntimeState{101, true});
  owner.receive<WorkspaceList>();
  ProtocolPeer slow{socket, false};
  slow.send(RequestRuntimeState{102, true});
  slow.receive<WorkspaceList>();
  ProtocolPeer control{socket};
  const std::array<std::string_view, 2> arguments{executable, "--child"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = launch});
  std::array<std::uint64_t, 3> panes{opened.pane_id};
  for (unsigned index = 1; index < panes.size(); ++index) {
    panes[index] = owner.exchange<PaneOpened>(CreatePane{.request_id = index + 1, .location = opened.location, .size = {80, 24, 0, 0}, .launch = launch}).pane_id;
  }
  for (const auto pane : panes) {
    waitForText(control, pane, "ready");
    slow.exchange<PaneOpened>(OpenPane{.request_id = 4, .target = PaneTarget{.kind = PaneTarget::Kind::pane, .id = pane}, .size = {80, 24, 0, 0}});
  }
  settle(slow);

  control.exchange<RequestCompleted>(SendPaneText{.request_id = 5, .pane_id = panes[0], .mode = PaneTextMode::raw, .text = "\x1b]2;Anchor\x1b\\"});
  check(slow.receive<PaneTitle>().title == "Anchor");
  settle(slow);
  blockOutput(slow, owner, control);
  for (unsigned index = 0; index < panes.size(); ++index) {
    const auto title = "Rotated" + std::to_string(index);
    const auto bytes = "\x1b]2;" + title + "\x1b\\\x1b]9;4;1;" + std::to_string(index + 1) + "\x1b\\";
    control.exchange<RequestCompleted>(SendPaneText{.request_id = 6, .pane_id = panes[index], .mode = PaneTextMode::raw, .text = bytes});
    check(owner.receive<PaneTitle>().title == title);
  }

  std::ofstream output{dump_path, std::ios::binary};
  for (const auto index : {1, 2, 0}) {
    const auto title = slow.receive<PaneTitle>();
    check(title.pane_id == panes[index] && title.title == "Rotated" + std::to_string(index));
    slow.record(output, title);
  }
  for (const auto index : {1, 2, 0}) {
    const auto progress = slow.receive<PaneProgress>();
    if (progress.pane_id != panes[index] || progress.percent != index + 1) {
      throw std::runtime_error{"Progress rotation expected pane " + std::to_string(panes[index]) + " at " + std::to_string(index + 1) + ", received pane " + std::to_string(progress.pane_id) + " at " + std::to_string(progress.percent.value_or(255))};
    }
    slow.record(output, progress);
  }
  check(slow.exchange<ClientList>(QueryClients{90}).entries.size() == 2);
  check(output.good());
}

int main(int argc, char **argv) {
  if (argc == 2 && std::string_view{argv[1]} == "--child") {
    return child();
  }
  if (argc != 5) {
    return 2;
  }
  try {
    const auto started = std::chrono::steady_clock::now();
    const std::string_view workload{argv[2]};
    if (workload == "state-current") {
      current(argv[1], argv[0], argv[4]);
    } else if (workload == "state-rotation") {
      rotation(argv[1], argv[0], argv[4]);
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
