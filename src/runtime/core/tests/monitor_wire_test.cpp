#include <climits>
#include <cstdlib>

import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.layout;
import telar.wire.monitor;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr ds::Array<std::string_view, 2> sleeper{"/bin/sleep", "600"};

  struct Listed {
    ProcessInstance instance{};
    std::int32_t nice = 0;
  };

  // The process the monitor lists for `pane`, as a client that asks the runtime sees it.
  ds::Option<Listed> processOf(ProtocolPeer& peer, std::uint64_t pane, std::uint64_t request) {
    const auto snapshot = peer.exchange<MonitorSnapshot>(QueryMonitor{
        .request_id = request,
        .sections = MonitorSections::processes,
        .sort = MonitorSort::pid,
        .scope = MonitorScope::telar,
        .limit = 300,
    });

    for (const auto& process : snapshot.processes) {
      if (process.pane_id == pane) {
        return Listed{.instance = process.instance, .nice = process.nice};
      }
    }

    return ds::none;
  }

  template <typename Settled>
  void await(std::string_view what, Settled&& settled) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    while (!settled()) {
      check(std::chrono::steady_clock::now() < deadline, what);
      std::this_thread::sleep_for(std::chrono::milliseconds{20});
    }
  }

  template <typename Request>
  ds::Option<FailureCode> refusal(ProtocolPeer& peer, const Request& request) {
    try {
      peer.exchange<RequestCompleted>(request);
      return ds::none;
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }
  }

  // The monitor lists the process a pane runs, lowers its priority and ends it, and refuses a signal
  // for a process instance that no longer is the one it names.
  void testMonitorActsOnTheProcessOfAPane() {
    RuntimeHost host;
    ProtocolPeer window{host.socket()};
    ProtocolPeer monitor{host.socket()};
    std::uint64_t request = 1;

    const auto opened = window.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Watched", .launch = Launch{.cwd = "/tmp", .arguments = sleeper}});
    ds::Option<Listed> listed;

    await("the monitor never listed the pane's process", [&] {
      listed = processOf(monitor, opened.pane_id, request++);
      return listed.hasValue();
    });

    auto stale = listed->instance;

    stale.started_seconds += 1;
    check(refusal(monitor, RequestProcessSignal{.request_id = request++, .process = stale, .signal = ProcessSignal::terminate}).hasValue(), "a signal must not reach a process that is not the instance it names");
    check(processOf(monitor, opened.pane_id, request++).hasValue(), "a refused signal must leave the process running");

    check(!refusal(monitor, RequestProcessPriority{.request_id = request++, .process = listed->instance, .nice = 5}), "lowering the priority of an own process must be allowed");
    await("the monitor never showed the new priority", [&] {
      const auto now = processOf(monitor, opened.pane_id, request++);
      return now && now->nice == 5;
    });

    check(!refusal(monitor, RequestProcessSignal{.request_id = request++, .process = listed->instance, .signal = ProcessSignal::terminate}), "ending an own process must be allowed");
    await("the process the monitor ended is still listed", [&] {
      return !processOf(monitor, opened.pane_id, request++);
    });
  }

  const telar::testing::Case case_monitor_acts_on_the_process_of_a_pane{"monitor_wire.monitor_acts_on_the_process_of_a_pane", testMonitorActsOnTheProcessOfAPane};

}
