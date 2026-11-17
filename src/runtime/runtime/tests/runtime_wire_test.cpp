#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.process;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.runtime.runtime.tests.wire_session;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr std::array<std::string_view, 1> cat{"/bin/cat"};

  // The process a pane runs under an agent's executable name: the test binary, copied as `name`
  // into the host's directory, in the --pane-agent mode below.
  std::string agentExecutable(const RuntimeHost& host, std::string_view name) {
    const telar::runtime::ExecutablePath self;
    const auto path = host.directory() + "/" + std::string{name};

    if (!std::filesystem::exists(path)) {
      std::filesystem::copy_file(self.c_str(), path);
    }

    return path;
  }

  void testUnknownTagDropsOnlySender() {
    RuntimeHost host;
    ProtocolPeer bystander{host.socket()};
    ProtocolPeer sender{host.socket()};

    check(bystander.exchange<ClientList>(QueryClients{.request_id = 1}).request_id == 1);

    // A frame of one byte whose tag no request has.
    constexpr std::array<Byte, 5> frame{1, 0, 0, 0, 0xee};

    check(::send(sender.descriptor(), frame.data(), frame.size(), 0) == static_cast<ssize_t>(frame.size()));
    check(closedByRuntime(sender.descriptor(), std::chrono::seconds{5}), "the runtime kept the client that sent an unknown tag");

    // The runtime keeps serving the other client.
    check(bystander.exchange<ClientList>(QueryClients{.request_id = 2}).request_id == 2);
  }

  void testIdleHandshakesExpire() {
    RuntimeHost host;
    std::vector<int> idle;

    // Connections that never say hello, as half-open bridges leave, take every handshake slot.
    for (std::size_t index = 0; index < 16; ++index) {
      const int descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
      sockaddr_un address{};

      address.sun_family = AF_UNIX;
      std::strncpy(address.sun_path, host.socket(), sizeof(address.sun_path) - 1);
      check(::connect(descriptor, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
      idle.push_back(descriptor);
    }

    // The runtime closes them once their handshake time runs out, and a client is served again.
    for (const int descriptor : idle) {
      check(closedByRuntime(descriptor, std::chrono::seconds{10}), "an idle handshake kept its slot");
      ::close(descriptor);
    }

    ProtocolPeer peer{host.socket()};

    check(peer.exchange<ClientList>(QueryClients{.request_id = 1}).request_id == 1);
  }

  void testPaneIdentityEnvironment() {
    RuntimeHost host;
    ProtocolPeer peer{host.socket()};
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "env | grep '^TELAR_' | sort; echo identity-done; exec cat"};
    const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    const auto screen = screenShowing(peer, opened.pane_id, "identity-done");
    const auto expect = [&](std::string_view name, const std::string& value) {
      check(screen.contains(std::string{name} + "=" + value + "\n"), name);
    };

    expect("TELAR_PANE_ID", std::to_string(opened.pane_id));
    expect("TELAR_PANE_GENERATION", std::to_string(opened.pane_generation));
    expect("TELAR_WORKSPACE_ID", std::to_string(opened.location.workspace.id));
    expect("TELAR_TAB_ID", std::to_string(opened.location.tab_id));
    expect("TELAR_SOCKET_PATH", host.socket());
  }

  void testSendTextRefusals() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const SendPaneText focused_text{.request_id = 2, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .mode = PaneTextMode::raw, .text = "typed-into-focus\r"};

    {
      // A window shows the pane focused, so text an agent sends would land in what the human types.
      ProtocolPeer window{host.socket()};
      const std::array<ClientLayoutNode, 1> nodes{ClientLayoutPane{opened.pane_id}};
      const std::array<ClientTabLayout, 1> layouts{ClientTabLayout{opened.location, opened.pane_id, false, true, nodes}};

      window.send(RequestRuntimeState{.client_identity = 71, .interactive = true});
      window.send(UpdateClientLayout{true, 29, false, opened.location, layouts});
      window.exchange<ClientList>(QueryClients{.request_id = 3});
      check(refusal(control, focused_text) == FailureCode::pane_focused, "text reached a focused pane");
    }

    // Once no window shows the pane focused, text is typed, and the refused text never was.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    auto delivered = focused_text;

    delivered.text = "typed-after-focus\r";
    while (refusal(control, delivered) == FailureCode::pane_focused) {
      check(std::chrono::steady_clock::now() < deadline, "the departed window still holds focus");
      ++delivered.request_id;
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }

    const auto screen = screenShowing(control, opened.pane_id, "typed-after-focus");

    check(!screen.contains("typed-into-focus"), "the refused text reached the pane");

    // A pane whose process exited takes no text: it refuses it as exited, or as gone once the
    // runtime retired the pane.
    const std::array<std::string_view, 1> exiting{"/usr/bin/true"};
    const auto exited = control.exchange<PaneOpened>(CreatePane{.request_id = 20, .location = opened.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = exiting}});

    waitExited(control, exited.pane_id);
    const auto late = refusal(control, SendPaneText{.request_id = 21, .pane_id = exited.pane_id, .pane_generation = exited.pane_generation, .mode = PaneTextMode::raw, .text = "late\r"});

    check(late == FailureCode::pane_exited || late == FailureCode::pane_not_found, "an exited pane took text");
  }

  void testBlockedAgentRefusesPrompt() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto result = host.directory() + "/agent-result";
    const auto codex = agentExecutable(host, "codex");
    const std::array<std::string_view, 5> arguments{codex, "--pane-agent", host.socket(), result, "blocked"};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    for (auto outcome = readFile(result); outcome != "blocked"; outcome = readFile(result)) {
      check(outcome.empty(), outcome);
      check(std::chrono::steady_clock::now() < deadline, "the agent never reported itself blocked");
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }

    // A prompt would answer the decision the agent waits for.
    const SendPaneText prompt{.request_id = 2, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .mode = PaneTextMode::prompt, .text = "yes"};

    check(refusal(control, prompt) == FailureCode::agent_blocked);
  }

  // Runs a fixture agent in a pane and returns what it recorded once the pane exited.
  std::string runAgent(std::string_view workload) {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto result = host.directory() + "/agent-result";
    const auto codex = agentExecutable(host, "codex");

    agentExecutable(host, "claude");
    const std::array<std::string_view, 5> arguments{codex, "--pane-agent", host.socket(), result, workload};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});

    waitExited(control, opened.pane_id);
    return readFile(result);
  }

  void testForeignReportRejected() {
    // A process the pane's agent started reports as another agent.
    const auto outcome = runAgent("nested");

    check(outcome == "foreign_process", outcome);
  }

  void testDeferredReportAnswered() {
    // The pane's agent replaced itself with another: its report waits until the process is checked
    // again, and is then accepted.
    const auto outcome = runAgent("replace");

    check(outcome == "completed", outcome);
  }

  void testOversizedLaunchKeepsSession() {
    RuntimeHost host{RuntimeHostOptions{.session = true}};
    WorkspaceLocation workspace;

    {
      ProtocolPeer control{host.socket()};
      const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});

      workspace = opened.location.workspace;
      // A restorable launch the wire admits, whose arguments with their separators exceed the
      // 128 KiB a checkpoint records.
      const std::string argument((128 * 1024 - 9) / 3, 'x');
      const std::array<std::string_view, 5> arguments{"/bin/echo", argument, argument, argument, std::string_view{"xx"}.substr(0, (128 * 1024 - 9) % 3)};

      try {
        control.exchange<PaneOpened>(CreatePane{.request_id = 2, .location = opened.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
        check(false, "the oversized launch opened a pane");
      } catch (const std::exception&) {
        // Refused or dropped: how the client learns of it is not the contract.
      }
    }

    ProtocolPeer control{host.socket()};
    const auto snapshot = control.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 3, .workspace = workspace});

    check(snapshot.tabs.size() == 1 && snapshot.tabs.front().pane_count == 1, "the refused launch registered a pane");
    control.exchange<WorkspaceSnapshot>(RenameWorkspace{.request_id = 4, .workspace = workspace, .name = "Kept after refusal"});
    const int status = host.stop();

    check(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    // The session written after the refusal still restores the other pane and the later rename.
    host.start();
    ProtocolPeer restored{host.socket()};

    restored.send(RequestRuntimeState{.client_identity = 5, .interactive = false});
    const auto list = restored.receive<WorkspaceList>();

    check(list.entries.size() == 1 && list.entries.front().workspace == workspace.id);
    check(list.entries.front().name == "Kept after refusal", "the session stopped being saved");
    const auto restored_snapshot = restored.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 6, .workspace = workspace});

    check(restored_snapshot.tabs.size() == 1 && restored_snapshot.tabs.front().pane_count == 1);
  }

  void testAttachmentSlotLimit() {
    RuntimeHost host;
    ProtocolPeer window{host.socket()};

    window.send(RequestRuntimeState{.client_identity = 61, .interactive = true});
    const auto first = window.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});

    // A window attaches every pane it opens: 64 fill one tab, and a second tab needs a 65th.
    for (std::uint64_t request = 2; request <= 64; ++request) {
      window.exchange<PaneOpened>(CreatePane{.request_id = request, .location = first.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    }

    check(refusal(window, CreateTab{.request_id = 65, .workspace = first.location.workspace, .label = "Past the limit", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}) == FailureCode::resource_limit);

    // The window still sees its first pane change.
    constexpr std::string_view typed = "after-limit\r";

    window.send(PaneInput{first.pane_id, {reinterpret_cast<const Byte*>(typed.data()), typed.size()}});
    window.deadline(std::chrono::seconds{5});
    for (;;) {
      const auto frame = window.receive<PaneFrame>();

      window.send(FrameAck{frame.pane_id, frame.frame_id});
      if (frame.pane_id == first.pane_id) {
        break;
      }
    }

    screenShowing(window, first.pane_id, "after-limit");
  }

  void testClosedTabResyncsObserver() {
    RuntimeHost host;
    ProtocolPeer owner{host.socket()};
    ProtocolPeer observer{host.socket()};

    owner.send(RequestRuntimeState{.client_identity = 81, .interactive = true});
    observer.send(RequestRuntimeState{.client_identity = 82, .interactive = true});
    const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto tab = owner.exchange<TabCreated>(CreateTab{.request_id = 2, .workspace = opened.location.workspace, .label = "Closed", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});

    // The observer shows the workspace's first pane.
    observer.exchange<PaneOpened>(OpenPane{.request_id = 3, .target = {.kind = PaneTarget::Kind::pane, .id = opened.pane_id}, .size = size});
    owner.exchange<TabClosed>(CloseTab{.request_id = 4, .location = tab.location});
    observer.deadline(std::chrono::seconds{5});
    const auto resync = observer.receive<ResyncRequired>();

    check(resync.workspace.id == opened.location.workspace.id && !resync.workspace_closed);
  }

  // The fixture side runs in a pane, so the runtime names its agent by the executable.
  void waitProvider(ProtocolPeer& peer, std::uint64_t pane, AgentProvider provider) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    for (std::uint64_t request = 100;; ++request) {
      const auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{request});
      if (std::ranges::any_of(snapshot.entries, [&](const auto& entry) {
            return entry.pane_id == pane && entry.provider == provider;
          })) {
        return;
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        throw std::runtime_error{"the runtime never named the pane's agent"};
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{5});
    }
  }

  std::string reportOutcome(ProtocolPeer& peer, const ReportAgent& report) {
    try {
      peer.exchange<RequestCompleted>(report);
      return "completed";
    } catch (const ProtocolFailure& failure) {
      return failure.code == FailureCode::foreign_process ? "foreign_process" : "refused " + std::to_string(static_cast<unsigned>(failure.code));
    }
  }

  // argv is {<directory>/codex|claude, --pane-agent, SOCKET, RESULT, WORKLOAD}; the outcome of the
  // workload goes to RESULT for the test to read.
  int paneAgent(int argc, char** argv) {
    if (argc != 5) {
      return 2;
    }

    const char* socket = argv[2];
    const std::string result = argv[3];
    const std::string_view workload = argv[4];

    try {
      const std::uint64_t pane = std::stoull(std::getenv("TELAR_PANE_ID"));
      const std::uint64_t generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
      const auto claude = (std::filesystem::path{argv[0]}.parent_path() / "claude").string();

      if (workload.ends_with("-report")) {
        ProtocolPeer peer{socket};

        peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
        const auto outcome = reportOutcome(peer, ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::claude, .state = AgentReportState::working, .event = "Reporting"});

        std::ofstream{result} << outcome;
        return 0;
      }

      // Output makes the runtime look at the pane's process.
      constexpr std::string_view clear = "\x1b[2J\x1b[H";

      check(::write(STDOUT_FILENO, clear.data(), clear.size()) == static_cast<ssize_t>(clear.size()));
      ProtocolPeer peer{socket};

      waitProvider(peer, pane, AgentProvider::codex);
      if (workload == "blocked") {
        peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .state = AgentReportState::blocked, .event = "Needs a decision"});
        std::ofstream{result} << "blocked";
        for (;;) {
          ::pause();
        }
      }

      const auto report = std::string{workload} + "-report";
      const char* arguments[] = {claude.c_str(), "--pane-agent", socket, result.c_str(), report.c_str(), nullptr};

      if (workload == "replace") {
        ::execv(arguments[0], const_cast<char* const*>(arguments));
        throw std::runtime_error{"cannot replace the agent"};
      }

      const auto child = ::fork();
      if (child == 0) {
        ::execv(arguments[0], const_cast<char* const*>(arguments));
        ::_exit(127);
      }

      int status = 0;

      while (::waitpid(child, &status, 0) < 0 && errno == EINTR) {
      }

      return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    } catch (const std::exception& error) {
      std::ofstream{result} << "error: " << error.what();
      return 1;
    }
  }

  const telar::testing::Mode pane_agent{"--pane-agent", paneAgent};

  const telar::testing::Case case_unknown_tag_drops_only_sender{"runtime_wire.unknown_tag_drops_only_sender", testUnknownTagDropsOnlySender};
  const telar::testing::Case case_idle_handshakes_expire{"runtime_wire.idle_handshakes_expire", testIdleHandshakesExpire};
  const telar::testing::Case case_pane_identity_environment{"runtime_wire.pane_identity_environment", testPaneIdentityEnvironment};
  const telar::testing::Case case_send_text_refusals{"runtime_wire.send_text_refusals", testSendTextRefusals};
  const telar::testing::Case case_blocked_agent_refuses_prompt{"runtime_wire.blocked_agent_refuses_prompt", testBlockedAgentRefusesPrompt};
  const telar::testing::Case case_foreign_report_rejected{"runtime_wire.foreign_report_rejected", testForeignReportRejected};
  const telar::testing::Case case_deferred_report_answered{"runtime_wire.deferred_report_answered", testDeferredReportAnswered};
  const telar::testing::Case case_oversized_launch_keeps_session{"runtime_wire.oversized_launch_keeps_session", testOversizedLaunchKeepsSession};
  const telar::testing::Case case_attachment_slot_limit{"runtime_wire.attachment_slot_limit", testAttachmentSlotLimit};
  const telar::testing::Case case_closed_tab_resyncs_observer{"runtime_wire.closed_tab_resyncs_observer", testClosedTabResyncsObserver};

}
