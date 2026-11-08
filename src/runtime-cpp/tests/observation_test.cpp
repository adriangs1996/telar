#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstring>
#include <cstddef>
#include <cstdint>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <cerrno>
#include <pthread.h>
#include <sys/types.h>
#include <unistd.h>
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>
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
import telar.runtime.tests.check;
import telar.runtime.observation.processor;
import telar.runtime.platform.request_worker;
import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

static void feedObserver(PaneObserver<SystemAllocator> &observer, std::string_view bytes) {
  observer.bytes(ObservationKind::output, {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()}, false);
}

static ScreenObservationResult observe(PaneObserver<SystemAllocator> &observer, AgentProvider provider) {
  check(observer.seal());
  const auto result = observer.observe(builtin_manifests, provider);
  observer.complete();
  check(!result.failed);
  return result;
}

static void testScreenOrdering(SystemAllocator &memory) {
  PaneObserver observer{memory, TerminalSize{80, 24, 8, 16}};
  feedObserver(observer, "\x1b[2J\x1b[20;1HWorking (12s)\x1b[22;1H› Ask Codex to do anything\x1b[22;3H");
  auto result = observe(observer, AgentProvider::codex);
  check(result.signal && result.signal->status == AgentStatus::working && result.signal->identity_confirmed);
  feedObserver(observer, "\x1b[?2026h\x1b[20;1H\x1b[2K\x1b[22;3H");
  result = observe(observer, AgentProvider::codex);
  check(!result.signal);
#if TELAR_DIAGNOSTICS
  check(result.metrics.resets == 0);
#endif
  feedObserver(observer, "\x1b[?2026l\x1b[");
  check(!observe(observer, AgentProvider::codex).signal);
  feedObserver(observer, "0m");
  result = observe(observer, AgentProvider::codex);
  check(result.signal && result.signal->status == AgentStatus::ready && result.signal->ready_confirmed);
  observer.resize({90, 24, 8, 16});
  check(!observe(observer, AgentProvider::codex).signal);

  feedObserver(observer, "\x1b[2J\x1b[1;1HClaude Code\x1b[22;1H❯ ");
  result = observe(observer, AgentProvider::claude);
  check(result.signal && result.signal->confidence == 96 && result.signal->identity_confirmed && result.signal->ready_confirmed);
  feedObserver(observer, "\x1b[23;1Hallow command?");
  result = observe(observer, AgentProvider::claude);
  check(result.signal && result.signal->status == AgentStatus::blocked && result.signal->confidence == 88);
  feedObserver(observer, "\x1b[23;1Hallow command?");
  check(!observe(observer, AgentProvider::claude).signal);
}

static void testDroppedObservation(SystemAllocator &memory) {
  PaneObserver observer{memory, TerminalSize{80, 24, 8, 16}};
  feedObserver(observer, "\x1b[22;1H› ");
  check(observer.seal());
  for (std::size_t index = 0; index <= ObservationBatch::event_capacity; ++index) {
    observer.resize({80, 24, 8, 16});
  }

  const auto drop = observer.takeDrop();
  check(drop && drop->name == "history.observer_batch_events" && drop->requested == 513);
  check(!observer.takeDrop());
  auto result = observer.observe(builtin_manifests, AgentProvider::codex);
  check(result.signal && result.signal->status == AgentStatus::ready);
  observer.complete();
  feedObserver(observer, "\x1b[22;1H› ");
  result = observe(observer, AgentProvider::codex);
  check(!result.signal);
#if TELAR_DIAGNOSTICS
  check(result.metrics.resets == 1 && result.metrics.failures == 0);
#endif
  feedObserver(observer, "\x1b[20;1HWorking (1s)\x1b[22;3H");
  result = observe(observer, AgentProvider::codex);
  check(result.signal && result.signal->status == AgentStatus::working);
  feedObserver(observer, "\x1b[20;1H\x1b[2K\x1b[22;3H");
  result = observe(observer, AgentProvider::codex);
  check(result.signal && result.signal->status == AgentStatus::ready);
}

static void testManifests() {
  auto manifests = builtin_manifests;
  check(manifests.fromExecutable("CLAUDE.EXE") == AgentProvider::claude);
  check(manifests.fromPath("C:\\node_modules\\@openai\\codex\\cli.js") == AgentProvider::codex);
  check(!manifests.detect("api pipe cursor opencode"));
  check(manifests.find(AgentProvider::codex)->commandField("exec_command") == "cmd");
  auto &custom = manifests.add("fixture-agent");
  custom.process_names.append("fixture");
  custom.brand.append("fixture");
  custom.working.append("fixture computing");
  custom.ready_prompt.append("fixture ready>");
  const auto signal = manifests.detect("FIXTURE READY>");
  check(signal && signal->provider == custom.provider && signal->ready_confirmed && signal->identity_confirmed);
  check(manifests.fromExecutable("fixture.js") == custom.provider);
  bool rejected = false;
  try {
    manifests.add("fixture-agent");
  } catch (const EncodingError &) {
    rejected = true;
  }
  check(rejected);
}

struct CompletionProbe {
  using Request = std::uint64_t;
  using Result = std::uint64_t;

  Result observe(const Request &request) noexcept {
    return request;
  }

  void stop() noexcept {}
};

static void testCompletionWakeups() {
  CompletionProbe probe;
  ObservationWorker<decltype(probe) &> worker{std::in_place, probe};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (std::uint64_t request = 1; request <= 1000; ++request) {
    check(worker.submit(request));
    bool completed = false;
    while (!completed) {
      worker.collect([&](std::uint64_t result) {
        check(result == request);
        completed = true;
      });
      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }

    pollfd notification{worker.descriptor(), POLLIN, 0};
    check(::poll(&notification, 1, 0) == 0);
  }
}

struct CaptureHistory {
  std::vector<std::string> commands;
  unsigned finished_sessions = 0;

  bool recordHistory(const HistoryEventView &event) noexcept {
    if (event.kind == HistoryEventKind::command_finished) {
      check(event.command.status == HistoryStatus::interrupted);
      commands.emplace_back(event.command.command);
    } else if (event.kind == HistoryEventKind::session_finished) {
      ++finished_sessions;
    }
    return true;
  }
};

struct UnusedAgents {
  const Agent *find(std::uint64_t, std::uint64_t) const noexcept {
    return nullptr;
  }

  void observeScreen(Pane<SystemAllocator> &, AgentSignal, ObservationTime) noexcept {}

  void observeProcess(Pane<SystemAllocator> &, const ProcessProbeResult &) noexcept {}
};

struct NoObservationFailures {
  void report(const LimitReach &) noexcept {
    check(false);
  }
};

struct DirectoryOnlyProbe {
  using Request = ProcessProbe<ProcessInspector>::Request;
  using Result = ProcessProbe<ProcessInspector>::Result;

  std::atomic<unsigned> calls{0};

  Result observe(const Request &) noexcept {
    ++calls;
    return {};
  }

  FixedText<4096> directory(pid_t) noexcept {
    FixedText<4096> path;
    path.assign("/observed");
    return path;
  }

  void stop() noexcept {}
};

struct DirectoryHistory {
  std::vector<std::pair<std::string, std::string>> commands;
  bool accept_commands = true;

  bool recordHistory(const HistoryEventView &event) noexcept {
    if (event.kind == HistoryEventKind::command_finished) {
      if (!accept_commands) {
        return false;
      }

      commands.emplace_back(event.command.command, event.command.directory);
    }

    return true;
  }
};

struct ChangedDirectoryProbe : DirectoryOnlyProbe {
  Result observe(const Request &request) noexcept {
    Result result;
    for (const auto &entry : std::span{request.panes}.first(request.count)) {
      auto &observed = result.panes[result.count++];
      observed.request = entry;
      observed.cwd.assign("/observed");
    }

    return result;
  }
};

static void testDirectoryChangesFollowQueuedCommands(SystemAllocator &memory) {
  for (const bool probe_process : {false, true}) {
    ChangedDirectoryProbe probe;
    DirectoryHistory history;
    auto observer = std::allocate_shared<PaneObserver<SystemAllocator>>(AllocatorRef<PaneObserver<SystemAllocator>, SystemAllocator>{memory}, memory, TerminalSize{80, 24, 8, 16}, "/initial");
    observer->configureHistory({.pane = 1, .workspace_path = "/initial", .shell = "/bin/sh"});
    ObservationProcessor<SystemAllocator, ChangedDirectoryProbe, DirectoryHistory> processor{builtin_manifests, probe, history};
    decltype(processor)::Request request;
    request.count = 1;
    request.entries[0].pane = 1;
    request.entries[0].observer = observer;
    request.entries[0].process_request = {.pane = 1, .root = 1};
    request.entries[0].probe_process = probe_process;

    const auto command = [&](std::string_view text) {
      feedObserver(*observer, "$ ");
      observer->bytes(ObservationKind::input, {reinterpret_cast<const Byte *>(text.data()), text.size()}, true);
      feedObserver(*observer, text);
      feedObserver(*observer, "\n");
      observer->shellExit(0);
      check(observer->seal());
      const auto result = processor.observe(request);
      check(result.count == 1 && !result.entries[0].screen.failed);
#if TELAR_DIAGNOSTICS
      const auto &metrics = result.entries[0].screen.metrics;
      check(metrics.candidate_input_bytes == text.size());
      check(metrics.captured == history.accept_commands && metrics.dropped == !history.accept_commands);
#endif
      observer->complete();
    };

    command("cd /observed\r");
    check(history.commands.size() == 1 && history.commands[0].first == "cd /observed");
    check(history.commands[0].second == "/initial");
    check(observer->observedDirectory() == "/observed");
    command("pwd\r");
    check(history.commands.size() == 2 && history.commands[1].first == "pwd");
    check(history.commands[1].second == "/observed");
    history.accept_commands = false;
    command("refused\r");
    check(history.commands.size() == 2);
  }
}

static void testPendingInputPreservesForegroundObservation(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  auto owned = makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits});
  auto &pane = *owned;
  model.panes.insert(1, std::move(owned));
  UnusedAgents agents;
  NoObservationFailures limits;
  DirectoryOnlyProbe probe;
  CaptureHistory history;
  PaneObservationService<SystemAllocator, decltype(agents), decltype(limits), decltype(probe), decltype(history)> service{limits, model.manifests, probe, history};
  const std::array<Byte, 1> editing{'x'};
  const std::array<Byte, 1> submitted{'\r'};
  pane.enqueueInput(editing);
  service.observe(model, agents, pane.id);
  pane.enqueueInput(submitted);

  pollfd completion{service.descriptor(), POLLIN, 0};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (pane.cwd != "/observed" && std::chrono::steady_clock::now() < deadline) {
    check(::poll(&completion, 1, 1000) == 1);
    service.collect(model, agents);
  }
  check(pane.cwd == "/observed" && pane.needs_foreground_observation);
}

static void testEmptyObservationRequiresExplicitRecheck(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  auto owned = makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits});
  auto &pane = *owned;
  model.panes.insert(1, std::move(owned));
  UnusedAgents agents;
  NoObservationFailures limits;
  DirectoryOnlyProbe probe;
  CaptureHistory history;
  PaneObservationService<SystemAllocator, decltype(agents), decltype(limits), decltype(probe), decltype(history)> service{limits, model.manifests, probe, history};
  const auto now = std::chrono::steady_clock::now();
  service.refresh(model, agents);
  service.refresh(model, agents);
  service.finish(model);
  check(probe.calls == 0 && pane.cwd == "/tmp");

  pane.process_recheck_requested = true;
  service.observe(model, agents, pane.id);
  pollfd completion{service.descriptor(), POLLIN, 0};
  const auto deadline = now + std::chrono::seconds{2};
  while (pane.process_rechecks == 0 && std::chrono::steady_clock::now() < deadline) {
    check(::poll(&completion, 1, 1000) == 1);
    service.collect(model, agents);
  }
  check(probe.calls == 1 && pane.process_rechecks == 1 && pane.cwd == "/observed");
}

static void testRetiredCapture(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  UnusedAgents agents;
  NoObservationFailures limits;
  ProcessInspector inspector;
  ProcessProbe probe{inspector};
  CaptureHistory history;
  PaneObservationService<SystemAllocator, decltype(agents), decltype(limits), decltype(probe), decltype(history)> service{limits, model.manifests, probe, history};
  for (unsigned index = 1; index <= 2; ++index) {
    auto observer = std::allocate_shared<PaneObserver<SystemAllocator>>(AllocatorRef<PaneObserver<SystemAllocator>, SystemAllocator>{memory}, memory, TerminalSize{20, 4, 8, 16});
    observer->configureHistory({.id = {static_cast<Byte>(index)}, .pane = index, .workspace_path = "/tmp", .shell = "/bin/sh"});
    feedObserver(*observer, "$ ");
    constexpr std::string_view input{"echo\r"};
    observer->bytes(ObservationKind::input, {reinterpret_cast<const Byte *>(input.data()), input.size()}, true);
    feedObserver(*observer, "echo\r\nresult");
    observer->retired_next = std::move(model.retired_observers);
    model.retired_observers = observer;
    ++model.retired_observer_count;
    service.refresh(model, agents);
    observer->finishSession();
  }

  service.finish(model);
  check(history.commands.size() == 2 && history.commands[0] == "echo" && history.commands[1] == "echo");
  check(history.finished_sessions == 2);
  check(!model.retired_observers && model.retired_observer_count == 0);
}

#if TELAR_DIAGNOSTICS
static void testCommandMetrics(SystemAllocator &memory) {
  PaneObserver observer{memory, TerminalSize{80, 24, 8, 16}};
  feedObserver(observer, "\x1b]133;A\x07$ \x1b]133;B\x07");
  const std::string_view command = "echo value\r";
  observer.bytes(ObservationKind::input, {reinterpret_cast<const Byte *>(command.data()), command.size()}, std::nullopt);
  feedObserver(observer, "echo value\r\n\x1b]133;C\x07value\r\n\x1b]133;D;0\x07");
  const auto first = observe(observer, AgentProvider::unknown);
  check(first.metrics.commands.osc_started == 4 && first.metrics.commands.osc_finished == 4);
  check(first.metrics.commands.captures == 1 && first.metrics.commands.auxiliary_completions == 1);
  feedObserver(observer, "\x1b]133;A\x07$ \x1b]133;B\x07");
  const auto next = observe(observer, AgentProvider::unknown);
  check(next.metrics.commands.osc_started == 2 && next.metrics.commands.captures == 0);
  check(next.metrics.commands.submissions == 0 && next.metrics.commands.auxiliary_completions == 0);
}
#endif

void testObservation() {
  SystemAllocator memory;
#if TELAR_DIAGNOSTICS
  testCommandMetrics(memory);
#endif
  testScreenOrdering(memory);
  testDroppedObservation(memory);
  testManifests();
  testCompletionWakeups();
  testRetiredCapture(memory);
  testPendingInputPreservesForegroundObservation(memory);
  testEmptyObservationRequiresExplicitRecheck(memory);
  testDirectoryChangesFollowQueuedCommands(memory);
}
