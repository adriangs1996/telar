#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif
#include <arpa/inet.h>
#include <csignal>
#include <netinet/in.h>
#include <sys/socket.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.agents.snapshot;
import telar.runtime.platform.process_probe;
import telar.platform.process;
import telar.wire.agents;
import telar.wire.vocabulary;
import telar.config.runtime;
import telar.runtime.platform.session_host;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string argumentBlock(std::initializer_list<std::string_view> arguments) {
    std::string bytes;

    for (const auto argument : arguments) {
      bytes.append(argument);
      bytes.push_back('\0');
    }

    return bytes;
  }

  void testArgumentIdentification() {
    const auto native = argumentBlock({"/usr/local/bin/codex", "--no-daemon", "resume", "session"});
    ProcessArguments arguments{native};

    check(arguments.provider(builtin_manifests, "codex") == AgentProvider::codex);
    check(arguments.sessionHost(AgentProvider::codex) == SessionHost::pane);
    check(arguments.sessionHost(AgentProvider::claude) == SessionHost::unknown);
    for (const auto batch : codex_batch_arguments) {
      const auto command = argumentBlock({"codex", "--no-daemon", batch});

      check(ProcessArguments{command}.sessionHost(AgentProvider::codex) == SessionHost::unknown);
    }

    const auto shared = argumentBlock({"codex", "resume", "session"});

    check(ProcessArguments{shared}.sessionHost(AgentProvider::codex) == SessionHost::shared_server);
    check(ProcessArguments{{}}.sessionHost(AgentProvider::codex) == SessionHost::unknown);
    const auto aliased = argumentBlock({"cursor-agent", "chat"});

    check(ProcessArguments{aliased}.provider(builtin_manifests, "unrecognized-launcher") == AgentProvider::cursor);
    const auto script = argumentBlock({"/usr/bin/node", "--trace-warnings", "--no-deprecation", "/pkg/@openai/codex/bin/codex.js"});

    check(ProcessArguments{script}.provider(builtin_manifests, "node") == AgentProvider::codex);
    check(ProcessArguments{script}.provider(builtin_manifests, "wrapper") == AgentProvider::codex);
    const auto user_script = argumentBlock({"node", "--inspect", "/project/app.js", "codex"});

    check(ProcessArguments{user_script}.provider(builtin_manifests, "node") == AgentProvider::unknown);
    const auto unrelated = argumentBlock({"python", "/project/codex.js"});

    check(ProcessArguments{unrelated}.provider(builtin_manifests, "python") == AgentProvider::unknown);

    auto custom = builtin_manifests;

    custom.add("fixture").process_names.append("custom-agent");
    const auto custom_script = argumentBlock({"node", "--trace-warnings", "custom-agent.js"});

    check(ProcessArguments{custom_script}.provider(custom, "node") == custom.named("fixture"));

    const int count = 3;
    std::string kernel(sizeof(count), '\0');

    std::memcpy(kernel.data(), &count, sizeof(count));
    kernel.append(argumentBlock({"/usr/local/bin/codex", {}, {}}));
    kernel.append(argumentBlock({"codex", "resume", "session", "exec"}));
    const auto parsed = ProcessArguments::fromMacos(kernel);

    check(parsed.provider(builtin_manifests, "unknown") == AgentProvider::codex);
    check(parsed.sessionHost(AgentProvider::codex) == SessionHost::shared_server);
    check(ProcessArguments::fromMacos(std::span{kernel}.first(2)).sessionHost(AgentProvider::codex) == SessionHost::unknown);
    kernel.resize(kernel.size() - 6);
    check(ProcessArguments::fromMacos(kernel).sessionHost(AgentProvider::codex) == SessionHost::unknown);
  }

  void testHookSettings(const std::filesystem::path& root) {
    const auto override_directory = root / "override";

    std::filesystem::create_directory(override_directory);
    std::filesystem::create_directory(root / ".codex");
    std::ofstream{root / ".codex/hooks.json"} << "{\"command\":\"telar hook codex\"}";
    check(codexHooksInstalled(nullptr, root.native()));
    check(codexHooksInstalled("", root.native()));
    check(!codexHooksInstalled(override_directory.c_str(), root.native()));
    std::ofstream{override_directory / "hooks.json"} << "{\"command\":\"telar hook codex\"}";
    check(codexHooksInstalled(override_directory.c_str(), {}));
    std::ofstream{override_directory / "hooks.json"} << std::string(32 * 1024, ' ') << " hook codex";
    check(!codexHooksInstalled(override_directory.c_str(), {}));
    std::filesystem::remove(override_directory / "hooks.json");
    check(::mkfifo((override_directory / "hooks.json").c_str(), 0600) == 0);
    check(!codexHooksInstalled(override_directory.c_str(), {}));
  }

  void testSharedServerEvidence() {
    Agent agent{1, 1};
    const ProcessIdentity identity{42, 1, 100, 0, 42};

    agent.observeProcess(identity, AgentProvider::codex, {100, 100});
    check(agent.setProcessContext(SessionHost::shared_server, true, identity));
    agent.observeScreen({AgentProvider::codex, AgentStatus::working, 78, true, false}, {200, 200});
    agent.project(5199);
    check(agent.event.view().empty());
    check(agent.project(5200));
    check(agent.event.view().ends_with("--no-daemon"));
    agent.observeScreen({AgentProvider::codex, AgentStatus::ready, 94, true, true}, {5300, 5300});
    check(agent.event.view().empty());
    agent.observeScreen({AgentProvider::codex, AgentStatus::working, 78, true, false}, {5400, 5400});
    agent.project(10'400);
    check(!agent.event.view().empty());
    agent.report(ReportAgent{.provider = AgentProvider::codex, .state = AgentReportState::working, .event = "Official report"}, {10'500, 10'500});
    check(agent.event.view() == "Official report");
    agent.report(ReportAgent{.provider = AgentProvider::codex, .state = AgentReportState::exited}, {10'600, 10'600});
    check(agent.event.view().empty());
    agent.setProcessContext(SessionHost::pane, true, identity);
    check(agent.in_pane);
    agent.project(100'000);
    check(agent.event.view().empty());
  }

  void testProcessCache() {
    ProcessCache cache;

    check(!cache.needsIdentification(0, false));
    check(cache.needsIdentification(42, false));
    for (unsigned attempt = 0; attempt < ProcessCache::acquisition_attempts; ++attempt) {
      check(cache.needsIdentification(42, false));
      cache.update(42, {}, false);
    }

    check(!cache.needsIdentification(42, false));
    check(cache.needsIdentification(42, true));
    check(cache.needsIdentification(43, false));
    cache.update(42, IdentifiedProcess{.provider = AgentProvider::codex, .session_host = SessionHost::shared_server}, true);
    check(cache.attempts == 0 && cache.hooks_installed);
    check(!cache.needsIdentification(42, false));
    check(cache.preferred(42) == AgentProvider::codex);
    check(cache.preferred(43) == AgentProvider::unknown);
    cache.update(43, {}, false);
    check(cache.attempts == 1 && !cache.hooks_installed);
    check(cache.preferred(43) == AgentProvider::unknown);
  }

  // The members run this test binary through hard links named after each agent, so the kernel
  // names their processes codex and claude. Copies would be new executables, and deleting them
  // while Gatekeeper still assesses them crashes syspolicyd and leaves every launch waiting on it
  // in _dyld_start; a link shares the binary's vnode, so there is nothing new to assess.
  void testGroupMembers(SystemAllocator& memory, const std::filesystem::path& root) {
    const ExecutablePath executable;
    std::filesystem::path directory = root;
    std::error_code error;

    std::filesystem::create_hard_link(executable.c_str(), directory / "codex", error);
    // A link cannot cross volumes, and the directory beside the binary is always on its volume.
    if (error == std::errc::cross_device_link) {
      auto beside = (std::filesystem::path{executable.view()}.parent_path() / "telar-process-test-XXXXXX").string();

      check(::mkdtemp(beside.data()) != nullptr);
      directory = beside;
      std::filesystem::create_hard_link(executable.c_str(), directory / "codex");
    } else {
      check(!error);
    }

    std::filesystem::create_hard_link(executable.c_str(), directory / "claude");
    const auto codex = (directory / "codex").string();
    const auto claude = (directory / "claude").string();
    const std::array<std::string_view, 6> arguments{"/bin/sh", "-c", "\"$1\" --process-identification-fixture & \"$2\" --process-identification-fixture & wait", "fixture", codex, claude};
    Command command{memory, Launch{.cwd = "/", .arguments = arguments}, CommandPurpose::administration};
    PipeProcess process{command.specification({})};
    ProcessInspector inspector;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    IdentifiedProcess selected_codex;
    IdentifiedProcess selected_claude;

    do {
      selected_codex = inspector.identifyGroup(process.processId(), AgentProvider::codex);
      selected_claude = inspector.identifyGroup(process.processId(), AgentProvider::claude);
      if (selected_codex.provider == AgentProvider::codex && selected_claude.provider == AgentProvider::claude) {
        break;
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    } while (std::chrono::steady_clock::now() < deadline);

    check(selected_codex.provider == AgentProvider::codex && selected_claude.provider == AgentProvider::claude);
    check(inspector.name(selected_codex.identity->pid).view() == "codex");
    check(inspector.name(selected_claude.identity->pid).view() == "claude");
    check(selected_codex.identity->pid != process.processId());
    check(selected_codex.identity->process_group == process.processId());
    check(selected_codex.session_host == SessionHost::shared_server && selected_codex.name.view() == "Codex");
    check(inspector.descendsFrom(*selected_codex.identity, process.processId()));

    ProcessProbe probe{inspector};
    ProcessProbe<ProcessInspector>::Request request;

    request.panes[0] = {.pane = 1, .generation = 2, .root = process.processId(), .foreground = process.processId(), .recheck = true};
    request.panes[0].cache.update(process.processId(), selected_codex, false);
    request.count = 1;
    const auto result = probe.observe(request);

    check(result.count == 1 && result.panes[0].provider == AgentProvider::codex);
    check(!result.panes[0].shell_foreground && result.panes[0].identity->pid == process.processId());
    check(result.panes[0].agent_identity == selected_codex.identity);
    if (directory != root) {
      std::filesystem::remove_all(directory);
    }
  }

  struct LeaderlessGroupInspector {
    mutable unsigned identifications = 0;

    ds::Option<ProcessIdentity> identity(pid_t process) const noexcept {
      return process == 10 ? ds::Option{ProcessIdentity{10, 1, 1, 0, 10}} : ds::none;
    }

    ds::Option<ProcessSnapshot> snapshot(pid_t process) const noexcept {
      const auto identified = identity(process);

      return identified ? ds::Option{ProcessSnapshot{*identified, 20}} : ds::none;
    }

    FixedText<4096> directory(pid_t) const noexcept {
      FixedText<4096> result;

      result.assign("/fixture");
      return result;
    }

    IdentifiedProcess identifyGroup(pid_t group, AgentProvider) const noexcept {
      ++identifications;
      return {.identity = ProcessIdentity{21, 1, 1, 0, group}, .provider = AgentProvider::claude};
    }

    ListeningPorts listeningPorts(pid_t) const noexcept {
      ListeningPorts ports;

      ports.add(3000);
      return ports;
    }
  };

  void testLeaderlessGroup() {
    LeaderlessGroupInspector inspector;
    ProcessProbe probe{inspector};
    ProcessProbe<LeaderlessGroupInspector>::Request request;

    request.panes[0] = {.pane = 1, .generation = 1, .root = 10, .foreground = 20};
    request.count = 1;
    auto result = probe.observe(request);

    check(result.count == 1 && result.panes[0].provider == AgentProvider::claude);
    check(result.panes[0].identity->pid == 20 && result.panes[0].agent_identity->pid == 21);
    check(!result.panes[0].shell_foreground);
    request.panes[0].cache = result.panes[0].cache;
    result = probe.observe(request);
    check(result.count == 1 && !result.panes[0].inspected && inspector.identifications == 1);
    check(!result.panes[0].ports_inspected && result.panes[0].ports.count == 0);
    request.panes[0].ports = true;
    result = probe.observe(request);
    check(result.panes[0].ports_inspected && result.panes[0].ports.view().size() == 1 && result.panes[0].ports.view().front() == 3000);
    request.panes[0].ports = false;
    request.panes[0].recheck = true;
    check(probe.observe(request).panes[0].inspected && inspector.identifications == 2);
    request.panes[0].foreground = 0;
    request.panes[0].discover_foreground = true;
    result = probe.observe(request);
    check(result.count == 1 && result.panes[0].request.foreground == 20);
    check(result.panes[0].identity->pid == 20 && result.panes[0].agent_identity->pid == 21);
  }

  void testListeningPortsOrder() {
    ListeningPorts ports;

    for (const std::uint16_t port : {8080, 0, 3000, 8080, 5173, 22, 9000}) {
      ports.add(port);
    }

    check(std::ranges::equal(ports.view(), std::array<std::uint16_t, 4>{22, 3000, 5173, 8080}));
  }

  // The runtime's own process group holds a socket listening on an ephemeral port.
  void testListeningPorts() {
    FileDescriptor listener{::socket(AF_INET, SOCK_STREAM, 0)};

    check(static_cast<bool>(listener));
    sockaddr_in address{};

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(::bind(listener.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    socklen_t length = sizeof(address);

    check(::getsockname(listener.get(), reinterpret_cast<sockaddr*>(&address), &length) == 0);
    const auto port = ntohs(address.sin_port);
    const ProcessInspector inspector;
    const auto unlistened = inspector.listeningPorts(::getpgrp());

    check(std::ranges::find(unlistened.view(), port) == unlistened.view().end());
    check(::listen(listener.get(), 1) == 0);
    const auto listened = inspector.listeningPorts(::getpgrp());

    check(std::ranges::find(listened.view(), port) != listened.view().end() || listened.count == max_listed_ports);
  }

  void testTerminalForegroundSnapshot(SystemAllocator& memory) {
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "PS1='READY> '; export PS1; ENV=/dev/null; export ENV; exec /bin/sh -i"};
    Command command{memory, Launch{.cwd = "/", .arguments = arguments}};
    PtyProcess process{command.specification({80, 24, 0, 0})};
    ProcessInspector inspector;
    const auto prompt_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
    std::string output;

    while (!output.contains("READY> ")) {
      std::array<char, 256> bytes;
      const auto count = ::read(process.descriptor(), bytes.data(), bytes.size());
      if (count > 0) {
        output.append(bytes.data(), static_cast<std::size_t>(count));
      } else {
        check(count < 0 && (errno == EAGAIN || errno == EINTR));
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }

      check(std::chrono::steady_clock::now() < prompt_deadline);
    }

    const auto awaitGroup = [&](bool shell_foreground) {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};

      do {
        const auto group = process.foregroundProcessGroup();
        const auto snapshot = inspector.snapshot(process.processId());
        if (group && snapshot && (*group == process.processId()) == shell_foreground && snapshot->terminal_foreground == *group) {
          check(snapshot->identity == inspector.identity(process.processId()));
          ProcessProbe probe{inspector};
          ProcessProbe<ProcessInspector>::Request request;

          request.panes[0] = {.pane = 1, .generation = 1, .root = process.processId(), .discover_foreground = true};
          request.count = 1;
          const auto result = probe.observe(request);

          check(result.count == 1 && result.panes[0].request.foreground == *group);
          check(result.panes[0].shell_foreground == shell_foreground);
          return *group;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      } while (std::chrono::steady_clock::now() < deadline);

      check(false);
      return pid_t{-1};
    };

    check(awaitGroup(true) == process.processId());
    constexpr std::string_view input = "/bin/cat\r";

    check(::write(process.descriptor(), input.data(), input.size()) == static_cast<ssize_t>(input.size()));
    const auto child_group = awaitGroup(false);

    check(child_group > 0 && child_group != process.processId());
    check(::kill(-child_group, SIGTERM) == 0);
    check(awaitGroup(true) == process.processId());
    process.shutdown();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};

    while (!process.reap() && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }

    check(process.reap().hasValue() && !inspector.snapshot(process.processId()));
  }

  void testProcessIdentification() {
    SystemAllocator memory;
    std::array<char, 64> temporary;

    std::strcpy(temporary.data(), "/tmp/telar-process-test-XXXXXX");
    check(::mkdtemp(temporary.data()) != nullptr);
    const std::filesystem::path root{temporary.data()};

    testHookSettings(root);
    testTerminalForegroundSnapshot(memory);
    testGroupMembers(memory, root);
    std::filesystem::remove_all(root);
  }

  const telar::testing::Case case_process_identification{"process_identification.process_identification", testProcessIdentification};
  const telar::testing::Case case_argument_identification{"process_identification.argument_identification", testArgumentIdentification};
  const telar::testing::Case case_shared_server_evidence{"process_identification.shared_server_evidence", testSharedServerEvidence};
  const telar::testing::Case case_process_cache{"process_identification.process_cache", testProcessCache};
  const telar::testing::Case case_leaderless_group{"process_identification.leaderless_group", testLeaderlessGroup};
  const telar::testing::Case case_listening_ports_order{"process_identification.listening_ports_order", testListeningPortsOrder};
  const telar::testing::Case case_listening_ports{"process_identification.listening_ports", testListeningPorts};

  // The group members the tests start run this executable until they are killed.
  const telar::testing::Mode identification_fixture{
      "--process-identification-fixture",
      [](int, char**) -> int {
        for (;;) {
          ::pause();
        }
      },
  };

}
