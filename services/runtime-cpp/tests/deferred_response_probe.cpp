#include <termios.h>
#include <cstdio>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.base.diagnostics;
import telar.runtime.tests.backpressure;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

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

static void exercise(const char *socket, const char *executable, std::string_view workload, const char *dump_path) {
  ProtocolPeer owner{socket};
  owner.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  owner.receive<WorkspaceList>();
  ProtocolPeer slow{socket};
  slow.send(RequestRuntimeState{.client_identity = 102, .interactive = true});
  slow.receive<WorkspaceList>();
  ProtocolPeer control{socket};
  const std::array<std::string_view, 2> arguments{executable, "--child"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = launch});
  waitForText(control, opened.pane_id, "ready");
  blockOutput(slow, owner, control);
  const ReadPane read{.request_id = 20, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .rows = 24};
  slow.send(read);
  slow.send(RequestTabSnapshot{21, opened.location});
  slow.send(RequestWorkspaceSnapshot{22, opened.location.workspace});
  slow.send(QueryLimits{23});
  barrier(slow, owner);

  std::ofstream output{dump_path, std::ios::binary};
  if (workload == "deferred-current") {
    control.exchange<RequestCompleted>(SendPaneText{.request_id = 30, .pane_id = opened.pane_id, .mode = PaneTextMode::raw, .text = "-updated"});
    waitForText(control, opened.pane_id, "ready-updated");
    owner.exchange<TabRenamed>(RenameTab{31, opened.location, "Current tab"});
    owner.exchange<WorkspaceSnapshot>(RenameWorkspace{32, opened.location.workspace, "Current workspace"});
    owner.exchange<PaneOpened>(CreatePane{.request_id = 33, .location = opened.location, .size = {80, 24, 0, 0}, .launch = launch});
    control.send(ReportLimit{.reach = LimitReach{.name = "deferred.capacity", .value = 10}, .hits = 4});
    const auto limits = control.exchange<LimitList>(QueryLimits{34});
    check(limits.entries.size() == 1 && limits.entries.front().hits == 4);

    const auto text = slow.receive<PaneText>();
    check(text.text == "ready-updated");
    slow.record(output, text);
    const auto tab = slow.receive<TabSnapshot>();
    check(tab.panes.size() == 2);
    slow.record(output, tab);
    const auto workspace = slow.receive<WorkspaceSnapshot>();
    check(workspace.name == "Current workspace" && workspace.tabs.front().label == "Current tab" && workspace.tabs.front().pane_count == 2);
    slow.record(output, workspace);
    auto listed = slow.receive<LimitList>();
    check(listed.entries.size() == 1 && listed.entries.front().hits == 4);
    std::vector<LimitListEntry> entries(listed.entries.begin(), listed.entries.end());
    for (auto &entry : entries) {
      entry.last_ms = 0;
    }
    listed.entries = entries;
    slow.record(output, listed);
  } else {
    owner.exchange<TabClosed>(CloseTab{.request_id = 30, .location = opened.location});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    for (;;) {
      const auto final = control.exchange<PaneText>(ReadPane{.request_id = 35, .pane_id = opened.pane_id, .rows = 24});
      if (final.exit_code) {
        break;
      }
      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(std::chrono::milliseconds{5});
    }
    const auto text = slow.receive<PaneText>();
    check(text.text == "ready" && text.exit_code.has_value());
    slow.record(output, text);
    check(slow.receive<TabSnapshot>().panes.empty());
    const auto closed = slow.receive<RequestFailed>();
    check(closed.code == FailureCode::workspace_not_found && closed.message == "workspace closed before its snapshot was sent");
    slow.record(output, closed);
    check(slow.receive<LimitList>().entries.empty());
  }
  check(slow.exchange<ClientList>(QueryClients{40}).entries.size() == 2);
  output << "client-connected\n";
  check(output.good());
}

static void roundtrips(const char *socket, const char *executable, unsigned iterations, const char *dump_path) {
  ProtocolPeer owner{socket};
  const std::array<std::string_view, 2> arguments{executable, "--child"};
  const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  ProtocolPeer reader{socket};
  waitForText(reader, opened.pane_id, "ready");
  std::ofstream output{dump_path, std::ios::binary};
  for (unsigned index = 0; index < iterations; ++index) {
    reader.record(output, reader.exchange<PaneText>(ReadPane{.request_id = index * 4 + 1, .pane_id = opened.pane_id, .rows = 24}));
    reader.record(output, reader.exchange<TabSnapshot>(RequestTabSnapshot{index * 4 + 2, opened.location}));
    reader.record(output, reader.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{index * 4 + 3, opened.location.workspace}));
    reader.record(output, reader.exchange<LimitList>(QueryLimits{index * 4 + 4}));
  }
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
    const auto workload = std::string_view{argv[2]};
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    const auto started = std::chrono::steady_clock::now();
    if (workload == "deferred-roundtrip") {
      roundtrips(argv[1], argv[0], iterations, argv[4]);
    } else if (workload == "deferred-current" || workload == "deferred-closed") {
      exercise(argv[1], argv[0], workload, argv[4]);
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
