#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <bit>
#include <cassert>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <climits>
#include <cmath>
#include <concepts>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <initializer_list>
#include <lauxlib.h>
#include <limits.h>
#include <lua.h>
#include <lualib.h>
#include <memory>
#include <mutex>
#include <optional>
#include <pcap/pcap.h>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <thread>
#include <unistd.h>
#include <utility>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#endif

import telar.testing;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.plugins.run_worker;
import telar.runtime.plugins.worker;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.process;
import telar.base.memory.sensitive;
import telar.config.runtime;
import telar.plugins;
import telar.runtime.platform.signals;
import telar.runtime.traffic.tap.exchange;
import telar.runtime.traffic.tap.protocol;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace tap = telar::runtime::plugins;

  int runPluginSessionFixture(std::string_view mode, bool traffic) {
    SystemAllocator system;
    BudgetAllocator budget{system, 128 * 1024 * 1024};
    MemoryAdapter adapter{budget};
    Memory& memory = adapter;

    if (mode.starts_with('/')) {
      tap::runWorker(memory, mode.data(), traffic);
      return 0;
    }

    if (mode == "blocked-write") {
      ::pause();
      return 0;
    }

    check(::getenv("HOME") == nullptr);
    ds::Array<char, PATH_MAX> cwd;

    check(::getcwd(cwd.dataMut(), cwd.size()) != nullptr && std::string_view{cwd.dataMut()} == "/");
    // "timeout-once:MARKER" stalls in the first session only: the marker it creates tells a
    // restarted session to answer.
    constexpr std::string_view stall_once = "timeout-once:";
    const bool stall = mode == "timeout" || (mode.starts_with(stall_once) && FileDescriptor{::open(std::string{mode.substr(stall_once.size())}.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600)});
    tap::PipeStream stream{tap::PipeEnds{.input = STDIN_FILENO, .output = STDOUT_FILENO}};
    tap::FrameChannel channel{stream};
    ds::Array<Byte, tap::Limits::effect_bytes> output;
    unsigned count = 0;

    while (auto frame = channel.receive(memory, tap::Limits::frame_bytes)) {
      ++count;
      const auto exchange = tap::Protocol::decodeExchange(frame->bytes());
      const auto event_id = exchange.identity.id;

      if (mode == "closed") {
        return 0;
      }

      if (stall) {
        ::pause();
        return 0;
      }

      if (mode == "oversized") {
        const ds::Array<Byte, 4> prefix{1, 0, 1, 0};

        check(writeDescriptor(STDOUT_FILENO, prefix) == 0);
        continue;
      }

      if (mode == "invalid") {
        channel.send(ds::Array<Byte, 1>{255});
        continue;
      }

      if (mode == "callback-error" && count == 1) {
        channel.send(tap::Protocol::encodeError(output.viewMut(), event_id, "callback failed"));
        continue;
      }

      if (mode == "stderr") {
        ds::Array<Byte, 4096> bytes;

        bytes.fill('e');
        for (unsigned index = 0; index < 256; ++index) {
          check(writeDescriptor(STDERR_FILENO, bytes) == 0);
        }
      }

      tap::EffectBatch effects;

      effects.count = 1;
      effects.notifications.atMut(0) = {.level = NotificationLevel::info, .duration_ms = 4000, .title = count == 1 ? "first" : "next", .message = "fixture"};
      channel.send(tap::Protocol::encodeEffects(output.viewMut(), mode == "stale" ? event_id + 1 : event_id, effects));
    }

    return 0;
  }

  void testRestartWindow() {
    using namespace std::chrono_literals;
    tap::RestartWindow burst;

    for (unsigned index = 0; index < 4; ++index) {
      check(!burst.record(0ms));
    }

    check(burst.record(10min));

    tap::RestartWindow spread;

    check(!spread.record(0ms));
    for (unsigned index = 0; index < 4; ++index) {
      check(!spread.record(10min + 1ms));
    }

    check(!spread.record(10min + 2ms));
    check(spread.record(10min + 3ms));
  }

  void testPluginSessions() {
    SystemAllocator system;
    BudgetAllocator budget{system, 4 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    const ExecutablePath executable;
    const std::string executable_path{executable.view()};
    CancellationSignal cancellation;
    CaptureQuota quota{4096};
    ds::Array<Byte, 4096> output;
    CapturedExchange exchange{memory};
    const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};

    exchange.request = ds::makeBox<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {1, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "test", .started_at_ms = 1});
    exchange.request.getMut().appendHead("GET / HTTP/1.1\r\n\r\n");
    const auto frame = tap::Protocol::encodeExchange(output.viewMut(), {73, 1}, exchange);
    tap::ServiceSpec specification;

    specification.plugin_id = 19;
    specification.generation = 1;
    specification.declared.insert(tap::Capability::proxy_tap);
    specification.declared.insert(tap::Capability::notifications);
    specification.granted = specification.declared;

    for (const auto* mode : {"echo", "callback-error", "stderr"}) {
      tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = mode, .cancellation = cancellation}};
      const auto process = session.processId();
      auto first = session.exchange(specification, 73, frame);

      if (std::string_view{mode} == "callback-error") {
        check(!first);
      } else {
        check(first && first->batch().notifications[0].title == "first");
        check(first->authorized(specification));
        auto stale = specification;

        ++stale.generation;
        check(!first->authorized(stale));
        stale = specification;
        stale.digest.atMut(0) ^= 1;
        check(!first->authorized(stale));
      }

      if (std::string_view{mode} == "stderr") {
        check(session.retainedError().size() == tap::Limits::stderr_bytes);
      }

      const auto second = session.exchange(specification, 73, frame);

      check(second && second->batch().notifications[0].title == "next" && session.processId() == process);
    }

    for (const auto* mode : {"closed", "oversized", "invalid", "stale", "timeout", "blocked-write"}) {
      tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = mode, .cancellation = cancellation, .timeout = std::chrono::milliseconds{100}}};
      const bool timed = std::string_view{mode} == "timeout" || std::string_view{mode} == "blocked-write";
      bool rejected = false;

      try {
        if (std::string_view{mode} == "blocked-write") {
          SensitiveAllocation large{memory, 1024 * 1024};

          std::ranges::fill(large.bytesMut(), 0);
          session.exchange(specification, 73, large.bytes());
        } else {
          session.exchange(specification, 73, frame);
        }
      } catch (const SystemError& error) {
        rejected = !timed || error.code() == ETIMEDOUT;
      } catch (const EncodingError&) {
        rejected = !timed;
      }

      check(rejected);
    }

    {
      tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = "timeout", .cancellation = cancellation}};
      std::jthread cancel{[&] {
        std::this_thread::sleep_for(std::chrono::milliseconds{20});
        cancellation.request();
      }};

      bool cancelled = false;

      try {
        session.exchange(specification, 73, frame);
      } catch (const SystemError& error) {
        cancelled = error.code() == ECANCELED;
      }

      check(cancelled);
    }

    exchange.request.reset();
    check(budget.liveBytes() == 0 && quota.used() == 0);
  }

  // The worker the runtime starts for a plugin, `tap-worker ENTRY`, answers an exchange
  // with what the plugin's Lua returns; with `--traffic` it first answers the setup with
  // the registrations the plugin declared.
  void testRealWorkerRoundtrip() {
    SystemAllocator system;
    BudgetAllocator budget{system, 4 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    const ExecutablePath executable;
    const std::string executable_path{executable.view()};
    TemporaryDirectory directory{"/tmp/tlr-real-worker.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";
    CancellationSignal cancellation;

    {
      std::ofstream file{entry};

      file << R"lua(
local telar = require('telar')
return {on_exchange = function(exchange)
  return {telar.effect.notification{title = 'seen ' .. exchange.host}}
end}
)lua";
      check(file.good());
    }

    CaptureQuota quota{4096};
    ds::Array<Byte, 4096> output;
    CapturedExchange exchange{memory};
    const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};

    exchange.request = ds::makeBox<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {1, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "example.test", .started_at_ms = 1});
    exchange.request.getMut().appendHead("GET / HTTP/1.1\r\n\r\n");
    const auto frame = tap::Protocol::encodeExchange(output.viewMut(), {73, 1}, exchange);
    tap::ServiceSpec specification;

    specification.plugin_id = 19;
    specification.generation = 1;
    specification.declared.insert(tap::Capability::proxy_tap);
    specification.declared.insert(tap::Capability::notifications);
    specification.granted = specification.declared;

    {
      tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = entry.c_str(), .cancellation = cancellation}};

      for (unsigned index = 0; index < 2; ++index) {
        const auto result = session.exchange(specification, 73, frame);

        check(result && result->batch().count == 1 && result->batch().notifications[0].title == "seen example.test");
      }
    }

    {
      std::ofstream file{entry};

      file << R"lua(
local traffic = require('telar.traffic')
traffic.subscribe({events={packet=true}, filter='udp port 53'}, function() end)
return {}
)lua";
      check(file.good());
    }

    tap::ServiceSpec observer;

    observer.plugin_id = 20;
    observer.generation = 1;
    observer.name.assign("observer");
    observer.declared.insert(tap::Capability::traffic_observe);
    observer.granted = observer.declared;
    {
      tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = entry.c_str(), .cancellation = cancellation, .traffic = true}};
      ds::Array<Byte, 4096> setup;
      const auto reply = session.request(tap::TrafficProtocol::setup(setup.viewMut(), observer), tap::TrafficLimits::reply_bytes);
      const auto registrations = tap::TrafficProtocol::reply(reply.bytes());

      check(registrations.registration_count == 1 && registrations.registrations[0].filter.view() == "udp port 53");
    }

    exchange.request.reset();
    check(budget.liveBytes() == 0 && quota.used() == 0);
  }

  const telar::testing::Case case_plugin_sessions{"plugin_session.plugin_sessions", testPluginSessions};
  const telar::testing::Case case_restart_window{"plugin_session.restart_window", testRestartWindow};
  const telar::testing::Case case_real_worker_roundtrip{"plugin_session.real_worker_roundtrip", testRealWorkerRoundtrip};

  // The plugin runtime starts its workers from this executable, with the words
  // TapWorkerOptions::arguments writes: an entry path runs the real worker, traffic
  // included, and any other entry names a fixture mode.
  const telar::testing::Mode tap_worker{
      "tap-worker",
      [](int argc, char** argv) {
        if (argc < 3) {
          return 2;
        }

        const auto options = tap::TapWorkerOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});

        return runPluginSessionFixture(options.entry, options.traffic);
      },
  };

}
