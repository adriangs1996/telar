#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cassert>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif

import std;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.platform.fs;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.plugins.service;
import telar.platform.fs;
import telar.platform.process;
import telar.config.runtime;
import telar.plugins;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.plugins.worker;
import telar.runtime.vocabulary.exchange;
import telar.runtime.vocabulary.traffic;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace tap = telar::runtime::plugins;

  namespace {

    template <typename Condition>
    void awaitCondition(Condition&& condition) {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};

      while (!condition()) {
        check(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    }

    CapturedExchange captured(ConcurrentMemory& memory, CaptureQuota& quota) {
      CapturedExchange exchange{memory};
      const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};

      exchange.request = makeOwned<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {1, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "test", .started_at_ms = 1});
      exchange.request->appendHead("GET / HTTP/1.1\r\n\r\n");
      return exchange;
    }

    tap::ServiceSpec specification(const char* mode, bool notifications = true) {
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
      BudgetAllocator budget{system, 1024 * 1024};
      MemoryAdapter adapter{budget};
      Memory& memory = adapter;
      tap::ResultQueue<Memory> results;

      results.activate();
      const auto identity = specification("echo");
      const auto publish = [&](std::uint64_t event_id) {
        SensitiveAllocation storage{memory, 64};
        const auto size = tap::Protocol::encodeEffects(storage.bytes(), event_id, {}).size();

        results.publish(makeOwned<tap::Result<Memory>>(memory, identity, std::move(storage), 0, size));
      };

      publish(1);
      publish(2);
      unsigned delivered = 0;

      results.collect([&](const auto& result) {
        check(result.event_id == 1);
        ++delivered;
        publish(3);
      });

      check(delivered == 1);
      for (unsigned expected = 2; expected <= 3; ++expected) {
        pollfd ready{results.descriptor(), POLLIN, 0};

        check(::poll(&ready, 1, 0) == 1);
        results.collect([&](const auto& result) {
          check(result.event_id == expected);
        });
      }

      pollfd ready{results.descriptor(), POLLIN, 0};

      check(::poll(&ready, 1, 0) == 0);
      check(budget.liveBytes() == 0);
    }

    void testConcurrentResults() {
      SystemAllocator system;
      BudgetAllocator budget{system, 1024 * 1024};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
      tap::ResultQueue<ConcurrentMemory> results;

      results.activate();
      const auto identity = specification("echo");
      const auto publish = [&](std::uint64_t event_id) {
        SensitiveAllocation storage{memory, 64};
        const auto size = tap::Protocol::encodeEffects(storage.bytes(), event_id, {}).size();

        results.publish(makeOwned<tap::Result<ConcurrentMemory>>(memory, identity, std::move(storage), 0, size));
      };

      for (std::uint64_t index = 0; index <= tap::Limits::queue_depth; ++index) {
        publish(index);
      }

      for (std::uint64_t index = 0; index < tap::Limits::queue_depth; ++index) {
        results.collect([&](const auto& result) {
          check(result.event_id == index);
        });
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
          results.collect([&](const auto& result) {
            check(result.event_id < delivered.size() && !delivered[result.event_id]);
            delivered[result.event_id] = true;
          });
        }

        check(std::ranges::all_of(delivered, [](bool received) {
          return received;
        }));

        check(::poll(&ready, 1, 0) == 0);
      }

      check(budget.liveBytes() == 0);
    }

    void testDelivery() {
      SystemAllocator system;
      BudgetAllocator budget{system, 8 * 1024 * 1024};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
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
            service.collect([&](const tap::EffectBatch& batch) {
              check(batch.count == 1 && batch.notifications[0].title == "first");
              ++notifications;
            });

            return notifications == 2;
          });
        } else {
          awaitCondition([&] {
            return quota.used() == 0;
          });

          service.collect([&](const tap::EffectBatch&) {
            ++notifications;
          });

          check(notifications == 0);
        }

        awaitCondition([&] {
          return quota.used() == 0 && service.heldBytes() == 0;
        });

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
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
      CaptureQuota quota{65536};
      const ExecutablePath executable;

      {
        const std::array specifications{specification("callback-error")};
        tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
        auto first = captured(memory, quota);

        service.submit(first);
        awaitCondition([&] {
          return quota.used() == 0;
        });

        auto second = captured(memory, quota);

        service.submit(second);
        unsigned delivered = 0;

        awaitCondition([&] {
          service.collect([&](const tap::EffectBatch& batch) {
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
          awaitCondition([&] {
            return quota.used() == 0;
          });
        }

        awaitCondition([&] {
          return service.metrics().disabled == 1;
        });

        check(service.listening());
        service.collect([](const tap::EffectBatch&) {
          check(false);
        });

        auto ignored = captured(memory, quota);

        service.submit(ignored);
        check(quota.used() == 0);
      }

      {
        const std::array specifications{specification("timeout")};
        tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};
        auto exchange = captured(memory, quota);

        service.submit(exchange);
        awaitCondition([&] {
          return service.heldBytes() > tap::Limits::frame_overhead;
        });

        const auto started = std::chrono::steady_clock::now();

        service.stop();
        check(std::chrono::steady_clock::now() - started < std::chrono::seconds{1});
        check(quota.used() == 0 && service.heldBytes() == 0);
      }

      check(budget.liveBytes() == 0 && quota.used() == 0);
    }

    // A worker the trust file grants, by name and package digest.
    tap::ServiceSpec trusted(std::string_view name) {
      auto result = specification("echo");

      result.name.assign(name);
      result.digest.fill(0x5a);
      return result;
    }

    // Replaces the trust file whole, as `telar plugin` saves it, readable by its owner only.
    void writeTrust(const std::string& path, std::string_view grants, mode_t mode = 0600) {
      const auto staged = path + ".new";

      {
        std::ofstream file{staged};

        file << "{\"version\":1,\"grants\":[" << grants << "]}";
        check(file.good());
      }

      check(::chmod(staged.c_str(), mode) == 0 && ::rename(staged.c_str(), path.c_str()) == 0);
    }

    std::string grant(std::string_view name, char digest = 'a') {
      std::string hex;

      for (std::size_t index = 0; index < tap::PackageDigest{}.size(); ++index) {
        hex.append({'5', digest});
      }

      return "{\"plugin\":\"" + std::string{name} + "\",\"digest\":\"" + hex + "\",\"capabilities\":[\"proxy.tap\",\"notifications\"]}";
    }

    // Withdrawing a plugin's grant, or granting another package under its name, stops the
    // running worker: it no longer listens, takes no new exchange, and the runtime drops
    // what it had already produced.
    void testTrustRevocationStopsWorker() {
      SystemAllocator system;
      BudgetAllocator budget{system, 8 * 1024 * 1024};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
      CaptureQuota quota{65536};
      const ExecutablePath executable;
      TemporaryDirectory directory{"/tmp/telar-plugin-trust.XXXXXX"};
      const auto path = std::string{directory.path()} + "/trust.json";

      for (const auto& replacement : {std::string{}, grant("trusted", 'b')}) {
        writeTrust(path, grant("trusted"));
        const std::array specifications{trusted("trusted")};
        tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};

        service.watchTrust(path);
        check(service.listening());
        auto exchange = captured(memory, quota);

        service.submit(exchange);
        pollfd ready{service.descriptor(), POLLIN, 0};

        check(::poll(&ready, 1, 3000) == 1);
        writeTrust(path, replacement);
        awaitCondition([&] {
          return !service.listening();
        });

        auto ignored = captured(memory, quota);

        service.submit(ignored);
        check(quota.used() == 0);
        service.collect([](const tap::EffectBatch&) {
          check(false);
        });
      }

      check(budget.liveBytes() == 0 && quota.used() == 0);
    }

    // A trust file that is gone, unreadable as JSON or open to other users keeps no grant
    // alive: watching it revokes every worker at once.
    void testUnreadableTrustRevokesAll() {
      SystemAllocator system;
      BudgetAllocator budget{system, 8 * 1024 * 1024};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;
      const ExecutablePath executable;
      TemporaryDirectory directory{"/tmp/telar-plugin-trust.XXXXXX"};
      const auto path = std::string{directory.path()} + "/trust.json";
      auto second = trusted("second");

      second.package_index = 1;
      second.plugin_id = 18;
      const std::array specifications{trusted("first"), second};
      const auto both = grant("first") + "," + grant("second");

      for (const auto damage : {0, 1, 2, 3}) {
        writeTrust(path, both);
        if (damage == 1) {
          check(::unlink(path.c_str()) == 0);
        } else if (damage == 2) {
          writeTrust(path, both + ",");
        } else if (damage == 3) {
          writeTrust(path, both, 0644);
        }

        tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, executable.c_str()};

        service.watchTrust(path);
        check(service.listening() == (damage == 0), std::to_string(damage));
      }

      check(budget.liveBytes() == 0);
    }
  }

  // Replaces trust.json at `path` in one rename, as `telar plugin trust` does, with one grant
  // for the tapper plugin.
  void writeTapperTrust(const std::string& path, std::string_view capabilities) {
    const auto staged = path + ".staged";

    {
      std::ofstream output{staged, std::ios::binary};

      output << R"({"version":1,"grants":[{"plugin":"tapper","digest":")" << std::string(64, '1') << R"(","capabilities":)" << capabilities << "}]}";
      check(output.good());
    }

    check(::chmod(staged.c_str(), 0600) == 0);
    std::filesystem::rename(staged, path);
  }

  // A running tap plugin keeps only the capabilities trust.json still grants it: narrowing its
  // grant stops it, while keeping or widening the grant leaves it running.
  void testTrustNarrowingStopsPlugin() {
    SystemAllocator system;
    BudgetAllocator budget{system, 8 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    const ExecutablePath executable;
    TemporaryDirectory directory{"/tmp/telar-plugin-trust-XXXXXX"};
    const auto path = std::string{directory.path()} + "/trust.json";

    {
      auto granted = specification("echo");

      granted.name.assign("tapper");
      granted.digest.fill(0x11);
      writeTapperTrust(path, R"(["proxy.tap","notifications"])");
      tap::Service service{memory, std::span<const tap::ServiceSpec>{&granted, 1}, executable.c_str()};

      service.watchTrust(path);
      check(service.listening());
      writeTapperTrust(path, R"(["proxy.tap","notifications","history.read"])");
      std::this_thread::sleep_for(tap::Limits::trust_check_interval * 4);
      check(service.listening());
      writeTapperTrust(path, R"(["proxy.tap"])");
      awaitCondition([&] {
        return !service.listening();
      });

      service.stop();
    }

    check(budget.liveBytes() == 0);
  }

  void testPluginService() {
    testQueuePolicy();
    testResultDeliveryBound();
    testConcurrentResults();
    testDelivery();
    testWorkerFailures();
  }

  const telar::testing::Case case_plugin_service{"plugin_service.plugin_service", testPluginService};
  const telar::testing::Case case_trust_revocation_stops_worker{"plugin_service.trust_revocation_stops_worker", testTrustRevocationStopsWorker};
  const telar::testing::Case case_unreadable_trust_revokes_all{"plugin_service.unreadable_trust_revokes_all", testUnreadableTrustRevokesAll};
  const telar::testing::Case case_trust_narrowing{"plugin_service.trust_narrowing_stops_plugin", testTrustNarrowingStopsPlugin};

}
