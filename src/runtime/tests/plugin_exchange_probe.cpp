#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstdio>
#include <poll.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.runtime.plugins.service;
import telar.vocabulary;

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

namespace {

  CapturedExchange captured(ConcurrentMemory& memory, CaptureQuota& quota, std::uint64_t index) {
    CapturedExchange exchange{memory};
    const ProxyCaptureLimits limits{.enabled = true};
    const CaptureStart request{.key = {index, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "example.test", .started_at_ms = 1};
    const CaptureStart response{.key = {index, 1}, .side = CaptureSide::response, .protocol = CaptureProtocol::http1, .host = "example.test", .started_at_ms = 1};

    exchange.request = makeOwned<CaptureHalf>(memory, memory, quota, limits, request);
    exchange.request->setMethod("POST");
    exchange.request->setTarget("/resource");
    exchange.request->appendHead("POST /resource HTTP/1.1\r\nHost: example.test\r\nContent-Length: 16\r\n\r\n");
    exchange.request->append(exchange.request->bodyPart(), "{\"value\":123456}");
    exchange.request->finish(CaptureOutcome::finished, 2);
    exchange.response = makeOwned<CaptureHalf>(memory, memory, quota, limits, response);
    exchange.response->appendHead("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n");
    exchange.response->append(exchange.response->bodyPart(), "ok");
    exchange.response->status_code = 200;
    exchange.response->finish(CaptureOutcome::finished, 3);
    return exchange;
  }

  void await(const tap::Service& service) {
    pollfd ready{service.descriptor(), POLLIN, 0};
    int count;

    do {
      count = ::poll(&ready, 1, 5000);
    } while (count < 0 && errno == EINTR);

    if (count <= 0) {
      throw SystemError{"Wait for plugin service result", count == 0 ? ETIMEDOUT : errno};
    }
  }

}

// Times exchanges through a tap plugin: the service hands each one to its worker thread, which
// encodes it for the plugin's process and publishes the effects it replies with. Prints the mean
// time per exchange and dumps every effect frame, which must match across builds.
int main(int argc, char** argv) {
  try {
    if (argc != 5) {
      throw std::invalid_argument{"Expected ENTRY WORKER_EXECUTABLE ITERATIONS DUMP"};
    }

    SystemAllocator system;
    BudgetAllocator budget{system, 512 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{tap::Limits::held_bytes};
    tap::ServiceSpec specification;

    specification.entry.assign(argv[1]);
    specification.plugin_id = 1;
    specification.generation = 1;
    specification.declared.insert(tap::Capability::proxy_tap);
    specification.declared.insert(tap::Capability::notifications);
    specification.granted = specification.declared;
    const std::array specifications{specification};
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, argv[2]};
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    std::ofstream dump{argv[4], std::ios::binary};
    std::array<Byte, tap::Limits::effect_bytes> output;
    std::uint64_t delivered = 0;

    // The first exchanges start the plugin's process and warm its interpreter.
    for (unsigned index = 0; index < 32; ++index) {
      auto exchange = captured(memory, quota, index);

      service.submit(exchange);
      await(service);
      service.collect([](const tap::EffectBatch&) {
      });
    }

    const auto started = std::chrono::steady_clock::now();

    for (unsigned index = 0; index < iterations; ++index) {
      auto exchange = captured(memory, quota, index);

      service.submit(exchange);
      await(service);
      service.collect([&](const tap::EffectBatch& batch) {
        const auto frame = tap::Protocol::encodeEffects(output, index, batch);

        dump.write(reinterpret_cast<const char*>(frame.data()), static_cast<std::streamsize>(frame.size()));
        ++delivered;
      });
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();

    if (delivered != iterations) {
      throw std::runtime_error{"The plugin did not reply to every exchange"};
    }

    std::printf("{\"ns_per_iteration\":%.2f}\n", static_cast<double>(elapsed) / iterations);
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "plugin-exchange-probe: %s\n", error.what());
    return 1;
  }
}
