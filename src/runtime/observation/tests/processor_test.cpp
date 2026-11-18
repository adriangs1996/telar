import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.config.runtime;
import telar.runtime.history.event;
import telar.runtime.observation.processor;
import telar.runtime.platform.process_probe;
import telar.sys.process;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  struct Finished {
    std::string command;
    HistoryAuthor author;
    std::string output;
  };

  struct FinishedCommands {
    std::vector<Finished> commands;

    bool recordHistory(const HistoryEventView& event) noexcept {
      if (event.kind == HistoryEventKind::command_finished) {
        const auto& output = event.command.output;

        commands.push_back({std::string{event.command.command}, event.command.author, std::string{reinterpret_cast<const char*>(output.data()), output.size()}});
      }

      return true;
    }
  };

  // A shell with semantic marks runs `command`, which prints `output`.
  void runCommand(PaneObserver& observer, FinishedCommands& history, std::string_view command, std::string_view output) {
    const auto typed = std::string{command} + "\r";

    observer.bytes(ObservationKind::output, bytes("\x1b]133;A\x07$ \x1b]133;B\x07"), true);
    observer.bytes(ObservationKind::input, bytes(typed), true);
    observer.bytes(ObservationKind::output, bytes(typed + "\n\x1b]133;C\x07" + std::string{output} + "\r\n\x1b]133;D;0\x07"), true);
    check(observer.seal());
    check(!observer.observe(builtin_manifests, AgentProvider::unknown, history).failed);
    observer.complete();
  }

  const HistorySession session{.id = {1}, .pane = 1, .workspace_path = "/tmp", .shell = "/bin/sh"};

  void testInjectedSubmissionAuthoredByAgent() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    PaneObserver observer{memory, TerminalSize{80, 24, 8, 16}};
    FinishedCommands history;

    observer.configureHistory(session);

    // An agent typed the next command; the one after it a human typed.
    observer.noteInjectedSubmission();
    runCommand(observer, history, "echo injected", "injected");
    runCommand(observer, history, "echo typed", "typed");
    check(history.commands.size() == 2 && history.commands[0].command == "echo injected" && history.commands[1].command == "echo typed");
    check(history.commands[0].author == HistoryAuthor::agent, "an injected command was recorded as typed");
    check(history.commands[1].author == HistoryAuthor::human, "a typed command was recorded as injected");
  }

  void testConfigureHistoryEnablesOutputCapture() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    // runtime.history.output reaches a pane only through its history configuration.
    for (const bool capture : {true, false}) {
      PaneObserver observer{memory, TerminalSize{80, 24, 8, 16}};
      FinishedCommands history;

      observer.configureHistory(session, capture);
      runCommand(observer, history, "echo captured", "captured-output");
      check(history.commands.size() == 1);
      check(history.commands[0].output.contains("captured-output") == capture, capture ? "the output was not captured" : "the output was captured");
    }
  }

  // Answers for every pane asked about, in the reverse order, each with its own directory.
  struct ReversedProbe {
    using Request = ProcessProbe<ProcessInspector>::Request;
    using Result = ProcessProbe<ProcessInspector>::Result;

    Result observe(const Request& request) noexcept {
      Result result;

      for (std::size_t index = request.count; index-- > 0;) {
        auto& observed = result.panes.atMut(result.count++);

        observed.request = request.panes[index];
        observed.provider = request.panes[index].pane == 1 ? AgentProvider::claude : AgentProvider::codex;
        observed.cwd.assign(request.panes[index].pane == 1 ? "/first" : "/second");
      }

      return result;
    }

    FixedText<4096> directory(pid_t) noexcept {
      return {};
    }

    void stop() noexcept {}
  };

  void testProcessorRoutesProcessResultsByPane() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    ReversedProbe probe;
    FinishedCommands history;
    ObservationProcessor<ReversedProbe, FinishedCommands> processor{builtin_manifests, probe, history};
    decltype(processor)::Request request;

    for (std::uint64_t pane = 1; pane <= 2; ++pane) {
      auto& entry = request.entries.atMut(request.count++);

      entry.pane = pane;
      entry.observer = std::allocate_shared<PaneObserver>(AllocatorRef<PaneObserver, ConcurrentMemory>{memory}, memory, TerminalSize{80, 24, 8, 16});
      entry.process_request = {.pane = pane, .root = static_cast<pid_t>(100 + pane)};
      entry.probe_process = true;
      entry.observer->bytes(ObservationKind::output, bytes("$ "), true);
      check(entry.observer->seal());
    }

    const auto result = processor.observe(request);

    check(result.count == 2);
    for (const auto& [index, provider, directory] : {std::tuple{0, AgentProvider::claude, "/first"}, std::tuple{1, AgentProvider::codex, "/second"}}) {
      const auto& entry = result.entries[index];

      check(entry.process_result.hasValue() && entry.process_result->request.pane == entry.pane, "a pane got another pane's process");
      check(entry.process_result->provider == provider && entry.process_result->cwd.view() == directory);
      check(entry.process_result->name.view() == builtin_manifests.find(provider)->displayName());
      check(entry.observer->observedDirectory() == directory);
      entry.observer->complete();
    }
  }

  const telar::testing::Case case_injected_submission_authored_by_agent{"observation.injected_submission_authored_by_agent", testInjectedSubmissionAuthoredByAgent};
  const telar::testing::Case case_configure_history_enables_output_capture{"observation.configure_history_enables_output_capture", testConfigureHistoryEnablesOutputCapture};
  const telar::testing::Case case_processor_routes_process_results_by_pane{"observation.processor_routes_process_results_by_pane", testProcessorRoutesProcessResultsByPane};

}
