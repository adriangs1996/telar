#include <csignal>
#include <cstdlib>
#include <termios.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.runtime.core.persistence.session_store;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.runtime.core.tests.wire_session;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr ds::Array<std::string_view, 1> cat{"/bin/cat"};
  constexpr std::string_view session_id = "0123abcd-4567-89ef-0123-456789abcdef";

  // A codex the runtime identifies by its executable, running `workload` in a pane: argv is
  // {<directory>/codex, --wire-agent, SOCKET, RESULT, WORKLOAD, ARGUMENT}. What it did goes to RESULT.
  int wireAgent(int argc, char** argv) {
    if (argc != 6) {
      return 2;
    }

    const char* socket = argv[2];
    const std::string result = argv[3];
    const std::string_view workload = argv[4];
    const std::string argument = argv[5];

    try {
      const std::uint64_t pane = std::stoull(std::getenv("TELAR_PANE_ID"));
      const std::uint64_t generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
      const std::uint64_t workspace = std::stoull(std::getenv("TELAR_WORKSPACE_ID"));
      constexpr std::string_view clear = "\x1b[2J\x1b[H";

      // Output makes the runtime look at the pane's process.
      check(::write(STDOUT_FILENO, clear.data(), clear.size()) == static_cast<ssize_t>(clear.size()));
      ProtocolPeer peer{socket};

      // A helper the runtime does not know as an agent reports one through the pane's hook, then exits.
      if (workload == "report-exit") {
        peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .state = AgentReportState::working, .event = "Fixture"});
        std::ofstream{result} << "seen";
        return 0;
      }

      waitProvider(peer, pane, AgentProvider::codex);
      if (workload == "titled" && std::filesystem::exists(argument)) {
        std::ofstream{result} << "idle";
        for (;;) {
          ::pause();
        }
      }

      peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
      const auto report = [&](std::uint64_t request, AgentReportState state) {
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = request, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .state = state, .event = "Fixture"});
      };

      if (workload == "sounds") {
        report(2, AgentReportState::working);
        report(3, AgentReportState::ready);
        report(4, AgentReportState::working);
        report(5, AgentReportState::blocked);
      } else if (workload == "progress") {
        peer.exchange<RequestCompleted>(ReportAgentProgress{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .cwd = argument + "/src", .work_tree_path = argument});
      } else if (workload == "register") {
        const auto registered = peer.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = 2, .source = workspace, .created_by = pane, .path = argument, .branch = "feature"});

        std::ofstream{result} << "registered " << registered.worktree;
        for (;;) {
          ::pause();
        }
      } else if (workload == "titled") {
        peer.exchange<RequestCompleted>(ReportAgentTitle{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .title = "Fix the parser"});
      } else if (workload == "working") {
        termios mode{};

        ::tcgetattr(STDIN_FILENO, &mode);
        ::cfmakeraw(&mode);
        ::tcsetattr(STDIN_FILENO, TCSANOW, &mode);
        report(2, AgentReportState::working);
        std::ofstream{result} << "working";
        ds::Array<char, 256> input;

        for (;;) {
          const auto count = ::read(STDIN_FILENO, input.dataMut(), input.size());
          if (count <= 0) {
            return 0;
          }

          std::ofstream{result + ".input", std::ios::app | std::ios::binary}.write(input.data(), count);
        }
      }

      std::ofstream{result} << "reported";
      for (;;) {
        ::pause();
      }
    } catch (const std::exception& error) {
      std::ofstream{result} << "error: " << error.what();
      return 1;
    }
  }

  const telar::testing::Mode wire_agent{"--wire-agent", wireAgent};

  // The fixture agent in a new pane of the control client's, once it wrote `expected`.
  struct FixtureAgent {
    FixtureAgent(const RuntimeHost& host, ProtocolPeer& control, std::string_view workload, std::string_view argument = "-", bool wrapped = false)
        : result(host.directory() + "/agent-" + std::string{workload}) {
      const auto codex = agentExecutable(host, "codex");
      const ds::Array<std::string_view, 6> direct{codex, "--wire-agent", host.socket(), result, workload, argument};
      const auto command = "exec '" + codex + "' --wire-agent '" + host.socket() + "' '" + result + "' " + std::string{workload} + " '" + std::string{argument} + "'";
      const ds::Array<std::string_view, 3> shell{"/bin/sh", "-c", command};
      const auto arguments = wrapped ? std::span<const std::string_view>{shell} : std::span<const std::string_view>{direct};

      opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    }

    std::string wait(std::string_view expected) const {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

      for (auto outcome = readFile(result);; outcome = readFile(result)) {
        if (outcome.starts_with(expected)) {
          return outcome;
        }

        check(!outcome.starts_with("error"), outcome);
        check(std::chrono::steady_clock::now() < deadline, "the agent never got to the expected step: " + outcome);
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
      }
    }

    std::string result;
    PaneOpened opened;
  };

  const AgentSnapshotEntry* agentOf(const AgentSnapshot& snapshot, std::uint64_t pane) {
    const auto found = std::ranges::find(snapshot.entries, pane, &AgentSnapshotEntry::pane_id);

    return found == snapshot.entries.end() ? nullptr : &*found;
  }

  void testSoundOnDoneAndBlocked() {
    RuntimeHost host;
    ProtocolPeer listener{host.socket()};
    ProtocolPeer bystander{host.socket()};
    ProtocolPeer control{host.socket()};

    listener.send(RequestRuntimeState{.client_identity = 61, .interactive = true});
    const FixtureAgent agent{host, control, "sounds"};

    // Done after working, then waiting on the user: one sound each, for windows that listen.
    listener.deadline(std::chrono::seconds{15});
    const auto ready = listener.receive<AgentSoundNotification>();
    const auto needs_input = listener.receive<AgentSoundNotification>();

    check(ready.pane_id == agent.opened.pane_id && ready.sound == AgentSound::ready);
    check(needs_input.pane_id == agent.opened.pane_id && needs_input.sound == AgentSound::needs_input);
    agent.wait("reported");
    bystander.send(QueryClients{.request_id = 2});
    check(std::holds_alternative<ClientList>(bystander.receiveAny<AgentSoundNotification, ClientList>()), "a client that does not listen heard the agent");
  }

  void testProgressRegistersExternalWorktree() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto worktree = host.directory() + "/external-checkout";

    std::filesystem::create_directories(worktree + "/src");
    const FixtureAgent agent{host, control, "progress", worktree};

    agent.wait("reported");
    ProtocolPeer window{host.socket()};

    window.send(RequestRuntimeState{.client_identity = 62, .interactive = false});
    const auto list = window.receive<WorkspaceList>();
    const auto found = std::ranges::find(list.worktrees, std::string_view{worktree}, &WorktreeListEntry::path);

    check(found != list.worktrees.end(), "the agent's worktree was not registered");
    check(found->branch == "external-checkout" && found->created_by == agent.opened.pane_id && found->origin == WorktreeOrigin::external);
    // The list views the peer's buffer, which the next reply reuses.
    const auto registered = found->worktree;
    const auto* entry = agentOf(window.exchange<AgentSnapshot>(QueryAgents{3}), agent.opened.pane_id);

    check(entry != nullptr && entry->work_tree == registered, "the agent is not linked to its worktree");
  }

  void testRegisterByVerifiedCreator() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto worktree = host.directory() + "/dispatched";
    const FixtureAgent agent{host, control, "register", worktree};
    const auto outcome = agent.wait("registered ");
    const auto identity = std::stoull(outcome.substr(11));
    ProtocolPeer window{host.socket()};

    window.send(RequestRuntimeState{.client_identity = 63, .interactive = false});
    const auto list = window.receive<WorkspaceList>();
    const auto found = std::ranges::find(list.worktrees, identity, &WorktreeListEntry::worktree);

    check(found != list.worktrees.end() && found->path == worktree && found->created_by == agent.opened.pane_id);
  }

  void testInterruptRefusalsAndDebounce() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const FixtureAgent agent{host, control, "working"};
    const auto pane = agent.opened.pane_id;
    const auto generation = agent.opened.pane_generation;

    agent.wait("working");

    // A pane with no agent working, and one whose process exited.
    const auto workspace = agent.opened.location.workspace;
    const auto plain = control.exchange<TabCreated>(CreateTab{.request_id = 2, .workspace = workspace, .label = "Plain", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const ds::Array<std::string_view, 1> exiting{"/usr/bin/true"};
    const auto exited = control.exchange<TabCreated>(CreateTab{.request_id = 3, .workspace = workspace, .label = "Exited", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = exiting}});

    check(refusal(control, InterruptAgent{4, plain.root_pane_id, plain.pane_generation}) == FailureCode::agent_not_working);
    waitExited(control, exited.root_pane_id);
    const auto late = refusal(control, InterruptAgent{5, exited.root_pane_id, exited.pane_generation});

    check(late == FailureCode::pane_exited || late == FailureCode::pane_not_found, "an exited pane took an interrupt");

    {
      // A window shows the agent's pane focused: the key would land in what the human types.
      ProtocolPeer window{host.socket()};
      const ds::Array<ClientLayoutNode, 1> nodes{ClientLayoutPane{pane}};
      const ds::Array<ClientTabLayout, 1> layouts{ClientTabLayout{agent.opened.location, pane, false, true, nodes}};

      window.send(RequestRuntimeState{.client_identity = 64, .interactive = true});
      window.send(UpdateClientLayout{true, 29, false, agent.opened.location, layouts});
      window.exchange<ClientList>(QueryClients{.request_id = 6});
      check(refusal(control, InterruptAgent{7, pane, generation}) == FailureCode::pane_focused);
    }

    // Once no window focuses it, two interrupts in a row send the key once.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    std::uint64_t request = 8;

    while (refusal(control, InterruptAgent{request, pane, generation}) == FailureCode::pane_focused) {
      check(std::chrono::steady_clock::now() < deadline, "the departed window still holds focus");
      ++request;
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }

    check(!refusal(control, InterruptAgent{request + 1, pane, generation}), "a repeated interrupt was refused");
    std::this_thread::sleep_for(std::chrono::milliseconds{300});
    check(readFile(agent.result + ".input") == "\x1b", "the agent did not get its interrupt key exactly once");
  }

  void testSendTextPromptBudget() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const Recorder target{host, control};
    const auto sender = control.exchange<PaneOpened>(CreatePane{.request_id = 2, .location = target.opened.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    ds::Option<FailureCode> ninth;

    // An agent in one pane prompts another in a loop.
    for (std::uint64_t index = 1; index <= 9; ++index) {
      const auto text = "prompt-" + std::to_string(index);

      ninth = refusal(control, SendPaneText{.request_id = 10 + index, .pane_id = target.opened.pane_id, .pane_generation = target.opened.pane_generation, .mode = PaneTextMode::prompt, .text = text, .sender = sender.pane_id});
    }

    check(ninth == FailureCode::prompt_rate_limited, "the ninth prompt was not limited");
    const auto received = target.received("prompt-8");

    check(!received.contains("prompt-9"), "the limited prompt reached the pane");
    check(received.substr(0, received.find("prompt-1")).contains(std::to_string(sender.pane_id)), "the prompt does not name the pane it came from");
  }

  // The session and title the checkpoint holds for `pane`.
  ds::Option<std::pair<std::string, std::string>> checkpointedAgent(const RuntimeHost& host, std::uint64_t pane) {
    const auto bytes = readFile(host.directory() + "/session.ckpt");
    ds::Option<std::pair<std::string, std::string>> found;
    telar::runtime::checkpoint::Reader reader{std::span{reinterpret_cast<const Byte*>(bytes.data()), bytes.size()}};

    reader.read([&]<typename Record>(const Record& record) {
      if constexpr (std::same_as<Record, telar::runtime::checkpoint::PaneRecord>) {
        if (record.id == pane) {
          found.emplace(std::string{record.session}, std::string{record.title});
        }
      }
    });

    return found;
  }

  void testReportSessionAndRestoredAgent() {
    RuntimeHost host{RuntimeHostOptions{.session = true, .resume_agents = true}};
    const auto restarted = host.directory() + "/restarted";
    std::uint64_t pane = 0;

    {
      ProtocolPeer control{host.socket()};
      // A shell starts the agent, so a restored pane types the resume instead of running it again.
      const FixtureAgent agent{host, control, "titled", restarted, true};

      pane = agent.opened.pane_id;
      agent.wait("reported");

      // The session a hook reports for the pane's agent, and requests for no live pane.
      check(!refusal(control, ReportAgentSession{.request_id = 2, .pane_id = pane, .pane_generation = agent.opened.pane_generation, .session = session_id}));
      check(refusal(control, ReportAgentSession{.request_id = 3, .pane_id = pane, .pane_generation = 0, .session = session_id}) == FailureCode::pane_not_found);
      check(refusal(control, ReportAgentSession{.request_id = 4, .pane_id = pane + 100, .pane_generation = 1, .session = session_id}) == FailureCode::pane_not_found);
    }

    const int status = host.stop();

    check(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    const auto saved = checkpointedAgent(host, pane);

    check(saved && saved->first == session_id && saved->second == "Fix the parser", "the reported session was not kept");

    // After a restart the agent comes back under its session and title before it reports again.
    std::ofstream{restarted} << "restarted";
    host.start();
    ProtocolPeer control{host.socket()};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    for (std::uint64_t request = 10;; ++request) {
      const auto* entry = agentOf(control.exchange<AgentSnapshot>(QueryAgents{request}), pane);
      if (entry != nullptr && entry->provider == AgentProvider::codex && entry->session_title == "Fix the parser") {
        break;
      }

      check(std::chrono::steady_clock::now() < deadline, "the restored agent lost its title");
      std::this_thread::sleep_for(std::chrono::milliseconds{20});
    }
  }

  void testShellForegroundRemovesAgent() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto helper = agentExecutable(host, "helper");
    const auto result = host.directory() + "/agent-report";
    const auto command = "'" + helper + "' --wire-agent '" + host.socket() + "' '" + result + "' report-exit -\r";
    const ds::Array<std::string_view, 2> shell{"/bin/sh", "-i"};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = shell}});

    // The user's shell runs a program whose hook reports an agent, and that program exits back to
    // the shell's prompt.
    control.send(PaneInput{opened.pane_id, {reinterpret_cast<const Byte*>(command.data()), command.size()}});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    while (readFile(result) != "seen") {
      check(std::chrono::steady_clock::now() < deadline, "the agent never reported");
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }

    for (std::uint64_t request = 10; agentOf(control.exchange<AgentSnapshot>(QueryAgents{request}), opened.pane_id) != nullptr; ++request) {
      check(std::chrono::steady_clock::now() < deadline, "the agent outlived its process");
      // Output makes the runtime look at the pane's process again.
      control.send(PaneInput{opened.pane_id, {reinterpret_cast<const Byte*>("\r"), 1}});
      std::this_thread::sleep_for(std::chrono::milliseconds{50});
    }
  }

  const telar::testing::Case case_sound_on_done_and_blocked{"agent_wire.sound_on_done_and_blocked", testSoundOnDoneAndBlocked};
  const telar::testing::Case case_progress_registers_external_worktree{"agent_wire.progress_registers_external_worktree", testProgressRegistersExternalWorktree};
  const telar::testing::Case case_register_by_verified_creator{"agent_wire.register_by_verified_creator", testRegisterByVerifiedCreator};
  const telar::testing::Case case_interrupt_refusals_and_debounce{"agent_wire.interrupt_refusals_and_debounce", testInterruptRefusalsAndDebounce};
  const telar::testing::Case case_send_text_prompt_budget{"agent_wire.send_text_prompt_budget", testSendTextPromptBudget};
  const telar::testing::Case case_shell_foreground_removes_agent{"agent_wire.shell_foreground_removes_agent", testShellForegroundRemovesAgent};
  const telar::testing::Case case_report_session_and_restored_agent{"agent_wire.report_session_and_restored_agent", testReportSessionAndRestoredAgent};

}
