#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <cstring>
#include <cassert>
#include <poll.h>
#include <sys/uio.h>
#include <unistd.h>
#include <sys/types.h>
#include <climits>
#include <csignal>
#include <cstdio>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <cstdlib>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.plugins.service;
import telar.platform;

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

namespace {

template <typename Condition>
void awaitCondition(Condition &&condition) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (!condition()) {
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

template <Allocator Memory>
CapturedExchange<Memory> captured(Memory &memory, CaptureQuota &quota) {
  CapturedExchange exchange{memory};
  const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};
  exchange.request = makeOwned<CaptureHalf<Memory>>(memory, memory, quota, limits, CaptureStart{.key = {1, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "test", .started_at_ms = 1});
  exchange.request->appendHead("GET / HTTP/1.1\r\n\r\n");
  return exchange;
}

tap::ServiceSpec specification(const char *mode, bool notifications = true) {
  tap::ServiceSpec result;
  result.plugin_id = 17;
  result.generation = 1;
  result.entry.assign(mode);
  result.declared.insert(tap::Capability::proxy_tap);
  result.declared.insert(tap::Capability::notifications);
  result.granted.insert(tap::Capability::proxy_tap);
  if (notifications) {
    result.granted.insert(tap::Capability::notifications);
  }
  return result;
}

void testQueuePolicy() {
  DropChannel<unsigned, 2, ChannelPolicy::keep_newest> newest;
  check(newest.publish(1) && newest.publish(2) && newest.publish(3));
  check(newest.tryReceive() == 2 && newest.tryReceive() == 3 && !newest.tryReceive());
  check(newest.metrics().dropped == 1 && newest.metrics().high_water == 2);
  newest.close();
  check(!newest.publish(4));

  DropChannel<unsigned, 2, ChannelPolicy::keep_oldest> oldest;
  check(oldest.publish(1) && oldest.publish(2) && !oldest.publish(3));
  check(oldest.tryReceive() == 1 && oldest.tryReceive() == 2 && !oldest.tryReceive());

  tap::TapBudget budget{10};
  {
    auto first = budget.charge(7);
    check(first && budget.used() == 7);
    check(!budget.charge(4) && budget.used() == 7 && budget.dropped() == 1);
    auto second = budget.charge(3);
    check(second && budget.used() == 10);
    auto moved = std::move(*first);
    first.reset();
    check(budget.used() == 10);
  }
  check(budget.used() == 0);
}

void testResultDeliveryBound() {
  SystemAllocator system;
  BudgetAllocator memory{system, 1024 * 1024};
  tap::ResultQueue<decltype(memory)> results;
  results.activate();
  const auto identity = specification("echo");
  const auto publish = [&](std::uint64_t event_id) {
    SensitiveAllocation storage{memory, 64};
    const auto size = tap::Protocol::encodeEffects(storage.bytes(), event_id, {}).size();
    results.publish(makeOwned<tap::Result<decltype(memory)>>(memory, identity, std::move(storage), 0, size));
  };
  publish(1);
  publish(2);
  unsigned delivered = 0;
  results.collect([&](const auto &result) {
    check(result.event_id == 1);
    ++delivered;
    publish(3);
  });
  check(delivered == 1);
  for (unsigned expected = 2; expected <= 3; ++expected) {
    pollfd ready{results.descriptor(), POLLIN, 0};
    check(::poll(&ready, 1, 0) == 1);
    results.collect([&](const auto &result) { check(result.event_id == expected); });
  }
  pollfd ready{results.descriptor(), POLLIN, 0};
  check(::poll(&ready, 1, 0) == 0);
  check(memory.liveBytes() == 0);
}

void testConcurrentResults() {
  SystemAllocator system;
  BudgetAllocator budget{system, 1024 * 1024};
  SynchronizedAllocator memory{budget};
  tap::ResultQueue<decltype(memory)> results;
  results.activate();
  const auto identity = specification("echo");
  const auto publish = [&](std::uint64_t event_id) {
    SensitiveAllocation storage{memory, 64};
    const auto size = tap::Protocol::encodeEffects(storage.bytes(), event_id, {}).size();
    results.publish(makeOwned<tap::Result<decltype(memory)>>(memory, identity, std::move(storage), 0, size));
  };

  for (std::uint64_t index = 0; index <= tap::Limits::queue_depth; ++index) {
    publish(index);
  }
  for (std::uint64_t index = 0; index < tap::Limits::queue_depth; ++index) {
    results.collect([&](const auto &result) { check(result.event_id == index); });
  }
  pollfd ready{results.descriptor(), POLLIN, 0};
  check(::poll(&ready, 1, 0) == 0);

  constexpr std::size_t producers = 4;
  for (unsigned round = 0; round < 16; ++round) {
    std::array<std::jthread, producers> threads;
    for (std::size_t producer = 0; producer < producers; ++producer) {
      threads[producer] = std::jthread{[&, producer] {
        for (std::size_t index = producer; index < tap::Limits::queue_depth; index += producers) {
          publish(index);
        }
      }};
    }

    std::array<bool, tap::Limits::queue_depth> delivered{};
    for (std::size_t index = 0; index < delivered.size(); ++index) {
      check(::poll(&ready, 1, 3000) == 1);
      results.collect([&](const auto &result) {
        check(result.event_id < delivered.size() && !delivered[result.event_id]);
        delivered[result.event_id] = true;
      });
    }
    check(std::ranges::all_of(delivered, [](bool received) { return received; }));
    check(::poll(&ready, 1, 0) == 0);
  }
  check(budget.liveBytes() == 0);
}

void testDelivery() {
  SystemAllocator system;
  BudgetAllocator budget{system, 8 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  CaptureQuota quota{65536};
  const ExecutablePath executable;
  {
    tap::Service service{memory, std::span<const tap::ServiceSpec>{}, executable.c_str()};
    check(!service.listening() && service.descriptor() == -1);
    auto exchange = captured(memory, quota);
    service.submit(exchange);
    check(!exchange.request && quota.used() == 0);
  }
  for (const bool authorized : {true, false}) {
    std::array specifications{specification("echo", authorized), specification("echo", authorized)};
    specifications[1].package_index = 1;
    specifications[1].plugin_id = 18;
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
    check(service.listening() && service.descriptor() >= 0);
    unsigned notifications = 0;
    auto exchange = captured(memory, quota);
    service.submit(exchange);
    check(!exchange.request);
    if (authorized) {
      awaitCondition([&] {
        service.collect([&](const tap::EffectBatch &batch) {
          check(batch.count == 1 && batch.notifications[0].title == "first");
          ++notifications;
        });
        return notifications == 2;
      });
    } else {
      awaitCondition([&] { return quota.used() == 0; });
      service.collect([&](const tap::EffectBatch &) { ++notifications; });
      check(notifications == 0);
    }
    awaitCondition([&] { return quota.used() == 0 && service.heldBytes() == 0; });
    const auto metrics = service.metrics();
    check(metrics.dropped_queue == 0 && metrics.dropped_bytes == 0 && metrics.disabled == 0 && metrics.timeouts == 0);
    service.stop();
    service.stop();
  }
  check(budget.liveBytes() == 0 && quota.used() == 0);
}

void testWorkerFailures() {
  SystemAllocator system;
  BudgetAllocator budget{system, 8 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  CaptureQuota quota{65536};
  const ExecutablePath executable;
  {
    const std::array specifications{specification("callback-error")};
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
    auto first = captured(memory, quota);
    service.submit(first);
    awaitCondition([&] { return quota.used() == 0; });
    auto second = captured(memory, quota);
    service.submit(second);
    unsigned delivered = 0;
    awaitCondition([&] {
      service.collect([&](const tap::EffectBatch &batch) {
        check(batch.count == 1 && batch.notifications[0].title == "next");
        ++delivered;
      });
      return delivered == 1;
    });
    check(service.metrics().disabled == 0);
  }
  {
    const std::array specifications{specification("stale")};
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
    for (unsigned attempt = 0; attempt < tap::Limits::restarts; ++attempt) {
      auto exchange = captured(memory, quota);
      service.submit(exchange);
      awaitCondition([&] { return quota.used() == 0; });
    }
    awaitCondition([&] { return service.metrics().disabled == 1; });
    check(service.listening());
    service.collect([](const tap::EffectBatch &) { check(false); });
    auto ignored = captured(memory, quota);
    service.submit(ignored);
    check(quota.used() == 0);
  }
  {
    const std::array specifications{specification("timeout")};
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
    auto exchange = captured(memory, quota);
    service.submit(exchange);
    awaitCondition([&] { return service.heldBytes() > tap::Limits::frame_overhead; });
    const auto started = std::chrono::steady_clock::now();
    service.stop();
    check(std::chrono::steady_clock::now() - started < std::chrono::seconds{1});
    check(quota.used() == 0 && service.heldBytes() == 0);
  }
  check(budget.liveBytes() == 0 && quota.used() == 0);
}

}

void testPluginService() {
  testQueuePolicy();
  testResultDeliveryBound();
  testConcurrentResults();
  testDelivery();
  testWorkerFailures();
}
