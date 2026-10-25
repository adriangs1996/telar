#include "check.hpp"
#include "client_peer.hpp"
#include "platform/host_metrics.hpp"
#include "runtime/metrics_service.hpp"
#include <poll.h>
#include <thread>

using namespace telar;
using namespace telar::runtime;

static constexpr std::uint64_t gib = std::uint64_t{1} << 30;

class FakeHostMetrics {
public:
  std::optional<HostCounters> read() noexcept {
    return next;
  }

  std::optional<HostCounters> next;
};

static void testProjection() {
  HostSampler sampler;
  check(!sampler.latest() && sampler.revision() == 1);
  HostCounters counters{.busy_ticks = 100, .total_ticks = 200, .memory_used_bytes = 3 * gib / 2, .memory_total_bytes = 16 * gib, .cpu_count = 8, .battery_percent = std::nullopt};
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
  HostMetricsReader reader{probe};
  const auto retained = reader.observe(sampler);
  check(retained.latest() == sampler.latest() && retained.revision() == sampler.revision());
#if TELAR_DIAGNOSTICS
  check(retained.diagnostics().sample.count == 1);
  check(retained.diagnostics().captured != std::chrono::steady_clock::time_point{});
#endif
}

static void testDelivery() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientPeer client{memory, model, ClientRole::interactive};
  FakeHostMetrics probe;
  probe.next = HostCounters{.busy_ticks = 2, .total_ticks = 10, .memory_used_bytes = 4 * gib, .memory_total_bytes = 16 * gib, .cpu_count = 8, .battery_percent = 81};
  const HostMetricsService<FakeHostMetrics>::Clock::time_point started{};
  HostMetricsService metrics{probe, started};
  metrics.publish(client.session());
  check(client.session().metrics_revision == 0);
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
  testProjection();
  testDelivery();
  NativeHostMetrics probe;
  const auto counters = probe.read();
  check(counters.has_value());
  check(counters->total_ticks >= counters->busy_ticks && counters->memory_used_bytes > 0 && counters->memory_total_bytes > 0 && counters->cpu_count > 0);
  check(!counters->battery_percent || *counters->battery_percent <= 100);
}
