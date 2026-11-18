#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <ghostty/vt.h>
#include <poll.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;

import telar.testing;
import telar.testing.test_memory;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.platform.stream_read_buffer;
import telar.runtime.runtime.client_control;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.runtime.metrics.host_sampler;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.host_metrics;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::uint64_t gib = std::uint64_t{1} << 30;

  class FakeHostMetrics {
  public:
    ds::Option<HostCounters> read() noexcept {
      return next;
    }

    ds::Option<HostCounters> next;
  };

  void testProjection() {
    HostSampler sampler;

    check(!sampler.latest() && sampler.revision() == 1);
    HostCounters counters{.busy_ticks = 100, .total_ticks = 200, .memory_used_bytes = 3 * gib / 2, .memory_total_bytes = 16 * gib, .cpu_count = 8, .battery_percent = ds::none};

    sampler.apply(counters);
    check(sampler.latest()->cpu_percent == 0 && sampler.revision() == 2);
    check(sampler.latest()->memory_used_decigib == 15 && sampler.latest()->memory_total_decigib == 160);

    counters.busy_ticks += 25;
    counters.total_ticks += 100;
    sampler.apply(counters);
    check(sampler.latest()->cpu_percent == 25 && sampler.revision() == 3);
    counters.busy_ticks += 25;
    counters.total_ticks += 100;
    sampler.apply(counters);
    check(sampler.revision() == 3);

    counters.battery_percent = 75;
    sampler.apply(counters);
    check(sampler.latest()->cpu_percent == 0 && sampler.latest()->battery_percent == 75 && sampler.revision() == 4);
    counters.busy_ticks = 1;
    counters.total_ticks = 1;
    sampler.apply(counters);
    check(sampler.latest()->cpu_percent == 0 && sampler.revision() == 4);

    counters.busy_ticks = std::numeric_limits<std::uint64_t>::max();
    counters.total_ticks = 2;
    counters.memory_used_bytes = std::numeric_limits<std::uint64_t>::max();
    sampler.apply(counters);
    check(sampler.latest()->cpu_percent == 100 && sampler.latest()->memory_used_decigib == 65535);

    FakeHostMetrics probe;
    HostMetricsReader<FakeHostMetrics&> reader{probe};
    const auto retained = reader.observe(sampler);

    check(retained.latest() == sampler.latest() && retained.revision() == sampler.revision());
#if TELAR_DIAGNOSTICS
    check(retained.diagnostics().sample.count == 1);
    check(retained.diagnostics().captured != std::chrono::steady_clock::time_point{});
#endif
  }

  void testDelivery() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    ClientPeer client{memory, model, clients, ClientRole::interactive};
    FakeHostMetrics probe;

    probe.next = HostCounters{.busy_ticks = 2, .total_ticks = 10, .memory_used_bytes = 4 * gib, .memory_total_bytes = 16 * gib, .cpu_count = 8, .battery_percent = 81};
    const HostMetricsService<FakeHostMetrics>::Clock::time_point started{};
    HostMetricsService<FakeHostMetrics&> metrics{started, probe};

    metrics.publish(client.session());
    client.session().subscribed = true;
    metrics.publish(client.session());
    check(client.session().metrics_revision == 1 && !client.session().connection.hasOutput());
    check(metrics.tick(started + std::chrono::seconds{1}) == std::chrono::seconds{1});
    metrics.tick(started + std::chrono::seconds{2});

    pollfd completion{.fd = metrics.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&completion, 1, 1000) == 1);
    for (unsigned attempt = 0; attempt < 1000 && client.session().metrics_revision != 2; ++attempt) {
      metrics.collect();
      metrics.publish(client.session());
      std::this_thread::yield();
    }

    check(client.session().metrics_revision == 2);
#if TELAR_DIAGNOSTICS
    check(metrics.diagnostics().sample.count == 1);
#endif
    const auto message = client.receive<SystemMetrics>();

    check(message.cpu_percent == 0 && message.cpu_count == 8 && message.memory_used_decigib == 40 && message.memory_total_decigib == 160);
    check(message.has_battery && message.battery_percent == 81);
    metrics.publish(client.session());
    check(!client.session().connection.hasOutput());
  }

  void testMetrics() {
    NativeHostMetrics probe;
    const auto counters = probe.read();

    check(counters.hasValue());
    check(counters->total_ticks >= counters->busy_ticks && counters->memory_used_bytes > 0 && counters->memory_total_bytes > 0 && counters->cpu_count > 0);
    check(!counters->battery_percent || *counters->battery_percent <= 100);
  }

  const telar::testing::Case case_metrics{"metrics.metrics", testMetrics};
  const telar::testing::Case case_projection{"metrics.projection", testProjection};
  const telar::testing::Case case_delivery{"metrics.delivery", testDelivery};

}
