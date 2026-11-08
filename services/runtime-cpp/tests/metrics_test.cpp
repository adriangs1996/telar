#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "client_peer.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <algorithm>
#include <limits>
#include <array>
#include <span>
#include <sys/types.h>
#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include <bit>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include <condition_variable>
#include <pthread.h>
#include <poll.h>
#include <thread>



import telar.runtime.platform.stream_read_buffer;
import telar.runtime.runtime.client_control;

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
  HostMetricsReader<FakeHostMetrics &> reader{probe};
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
  ClientStore<SystemAllocator> clients{memory};
  ClientPeer client{memory, model, clients, ClientRole::interactive};
  FakeHostMetrics probe;
  probe.next = HostCounters{.busy_ticks = 2, .total_ticks = 10, .memory_used_bytes = 4 * gib, .memory_total_bytes = 16 * gib, .cpu_count = 8, .battery_percent = 81};
  const HostMetricsService<FakeHostMetrics>::Clock::time_point started{};
  HostMetricsService<FakeHostMetrics &> metrics{started, probe};
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
