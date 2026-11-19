#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <poll.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;

import telar.testing;
import telar.testing.test_memory;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.host_metrics;
import telar.runtime.platform.process_probe;
import telar.runtime.platform.process_table;
import telar.wire.monitor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Two processes; the first spends a second of CPU between readings.
  struct FakeProcesses {
    std::uint64_t readings = 0;

    bool read(ds::Vec<ProcessRecord, ConcurrentMemory>& records) {
      for (pid_t pid : {4'000'001, 4'000'002}) {
        ProcessRecord record{.pid = pid, .started_seconds = 7, .measured = true, .resident_bytes = 4096, .threads = 1, .state = ProcessState::running};

        record.cpu_nanoseconds = pid == 4'000'001 ? readings * 1'000'000'000 : 0;
        record.name.assign(pid == 4'000'001 ? "busy" : "idle");
        records.push(record);
      }

      ++readings;
      return true;
    }
  };

  // One core, half busy.
  struct FakeHost {
    std::uint64_t readings = 0;

    bool read(HostDetail& detail) noexcept {
      ++readings;
      detail.core_count = 1;
      detail.cores.atMut(0) = {.busy = readings * 50, .total = readings * 100};
      detail.memory_total_bytes = 1000;
      detail.memory_used_bytes = 400;
      detail.memory_available_bytes = 600;
      return true;
    }
  };

  using Service = MonitorService<FakeProcesses, FakeHost>;

  void noRoots(MonitorWork&) {}

  // Waits for the worker and hands its outcome to `reply`.
  template <typename Reply>
  void finish(Service& service, Reply&& reply) {
    pollfd completion{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&completion, 1, 2000) == 1);
    service.collect(reply);
  }

  // A cold query waits for two readings, a second apart, and is answered after the second.
  void testColdQueryWaitsForTwoReadings() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    ClientPeer client{memory, model, clients, ClientRole::control};
    const ProcessInspector inspector;
    Service service{memory, inspector, FakeProcesses{}, FakeHost{}};
    const Service::Clock::time_point started{std::chrono::hours{1}};
    std::size_t replies = 0;
    const auto reply = [&](std::uint64_t, const auto& message) {
      ++replies;
      client.session().connection.send(message);
    };

    service.query(client.session().id, QueryMonitor{.request_id = 5, .sections = MonitorSections::host | MonitorSections::processes, .limit = 10}, started);
    check(service.tick(started, noRoots) == Service::warm_interval);
    finish(service, reply);
    check(replies == 0);
    check(service.tick(started + Service::warm_interval, noRoots) == Service::sample_interval);
    finish(service, reply);
    check(replies == 1);

    const auto snapshot = client.receive<MonitorSnapshot>();

    check(snapshot.request_id == 5 && snapshot.cores.size() == 1 && snapshot.cores[0] == 500);
    check(snapshot.processes.size() == 2 && snapshot.processes[0].name == "busy" && snapshot.processes[0].cpu_permille > 0);
    check(snapshot.matched == 2 && snapshot.memory_used_bytes == 400);
  }

  // Ten seconds after the last query the service stops reading the processes.
  void testIdlesWithoutQueries() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const ProcessInspector inspector;
    Service service{memory, inspector, FakeProcesses{}, FakeHost{}};
    const Service::Clock::time_point started{std::chrono::hours{1}};

    check(service.tick(started, noRoots) == std::chrono::hours{1});
    service.query(1, QueryMonitor{.request_id = 1, .sections = MonitorSections::host}, started);
    service.tick(started, noRoots);
    finish(service, [](std::uint64_t, const auto&) {});
    check(service.tick(started + Service::idle_after, noRoots) == std::chrono::hours{1});
  }

  // A signal for a pid that names no process fails as gone; an agent outside the target's pane may
  // not act on it.
  void testActions() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    ClientPeer client{memory, model, clients, ClientRole::control};
    const ProcessInspector inspector;
    Service service{memory, inspector, FakeProcesses{}, FakeHost{}};
    const Service::Clock::time_point started{std::chrono::hours{1}};
    const auto reply = [&](std::uint64_t, const auto& message) {
      client.session().connection.send(message);
    };

    service.act({.client = client.session().id, .request_id = 3, .process = {.pid = 4'000'009}, .signal = ProcessSignal::terminate});
    service.tick(started, noRoots);
    finish(service, reply);

    const auto gone = client.receive<RequestFailed>();

    check(gone.request_id == 3 && gone.code == FailureCode::process_not_found);

    // This test runs in no pane, yet as the process that asks: a root at its parent stands for an
    // agent's pane the target, the parent's parent, is outside of.
    const auto self = inspector.identity(::getpid());

    check(self.hasValue());
    service.act({.client = client.session().id, .request_id = 4, .process = {.pid = ::getppid()}, .signal = ProcessSignal::resume, .peer = self});
    service.tick(started, [&](MonitorWork& work) {
      work.roots.atMut(work.root_count++) = {.process = ::getpid(), .pane_id = 9, .agent = true};
    });

    finish(service, reply);
    check(client.receive<RequestFailed>().code == FailureCode::foreign_process);
  }

  const telar::testing::Case case_cold_query{"monitor_service.cold_query_waits_for_two_readings", testColdQueryWaitsForTwoReadings};
  const telar::testing::Case case_idles{"monitor_service.idles_without_queries", testIdlesWithoutQueries};
  const telar::testing::Case case_actions{"monitor_service.actions", testActions};

}
