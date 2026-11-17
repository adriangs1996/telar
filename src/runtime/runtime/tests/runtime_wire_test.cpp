#include <cerrno>
#include <poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.process;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr std::array<std::string_view, 1> cat{"/bin/cat"};

  // True once the runtime closed the peer's connection, reading and discarding what it sent first.
  bool closedByRuntime(int descriptor, std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    std::array<char, 4096> bytes;

    for (;;) {
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
      if (remaining.count() <= 0) {
        return false;
      }

      pollfd ready{.fd = descriptor, .events = POLLIN, .revents = 0};
      if (::poll(&ready, 1, static_cast<int>(remaining.count())) <= 0) {
        continue;
      }

      const auto count = ::recv(descriptor, bytes.data(), bytes.size(), 0);
      if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN)) {
        return true;
      }
    }
  }

  // The code a request failed with, or nothing when the runtime completed it.
  template <typename Request>
  std::optional<FailureCode> refusal(ProtocolPeer& peer, const Request& request) {
    try {
      peer.exchange<RequestCompleted>(request);
      return std::nullopt;
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }
  }

  // The pane's screen once it shows `marker`.
  std::string screenShowing(ProtocolPeer& peer, std::uint64_t pane, std::string_view marker) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    for (std::uint64_t request = 1000;; ++request) {
      const auto text = peer.exchange<PaneText>(ReadPane{.request_id = request, .pane_id = pane, .rows = 200});
      if (text.text.contains(marker)) {
        return std::string{text.text};
      }

      check(std::chrono::steady_clock::now() < deadline, "the pane never showed the expected text");
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  // Waits for the pane's PaneExited, which the client that opened the pane receives.
  void waitExited(ProtocolPeer& peer, std::uint64_t pane) {
    while (peer.receive<PaneExited>().pane_id != pane) {
    }
  }

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

  std::string readFile(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, {}};
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
  const telar::testing::Case case_pane_identity_environment{"runtime_wire.pane_identity_environment", testPaneIdentityEnvironment};
  const telar::testing::Case case_send_text_refusals{"runtime_wire.send_text_refusals", testSendTextRefusals};
  const telar::testing::Case case_blocked_agent_refuses_prompt{"runtime_wire.blocked_agent_refuses_prompt", testBlockedAgentRefusesPrompt};
  const telar::testing::Case case_foreign_report_rejected{"runtime_wire.foreign_report_rejected", testForeignReportRejected};
  const telar::testing::Case case_deferred_report_answered{"runtime_wire.deferred_report_answered", testDeferredReportAnswered};

}
