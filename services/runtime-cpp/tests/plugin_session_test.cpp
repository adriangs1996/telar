#include "check.hpp"
#include "platform/completion_signal.hpp"
#include "platform/executable_path.hpp"
#include "plugins/restart_window.hpp"
#include "plugins/run_worker.hpp"
#include "plugins/session.hpp"
#include "telar_platform/write_descriptor.hpp"
#include <thread>

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

int runPluginSessionFixture(std::string_view mode) {
  SystemAllocator system;
  BudgetAllocator memory{system, 128 * 1024 * 1024};
  if (mode.starts_with('/')) {
    tap::runWorker(memory, mode.data());
    return 0;
  }
  if (mode == "blocked-write") {
    ::pause();
    return 0;
  }

  check(::getenv("HOME") == nullptr);
  std::array<char, PATH_MAX> cwd;
  check(::getcwd(cwd.data(), cwd.size()) != nullptr && std::string_view{cwd.data()} == "/");
  tap::PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
  tap::FrameChannel channel{stream};
  std::array<Byte, tap::Limits::effect_bytes> output;
  unsigned count = 0;
  while (auto frame = channel.receive(memory, tap::Limits::frame_bytes)) {
    ++count;
    const auto exchange = tap::Protocol::decodeExchange(frame->bytes());
    const auto event_id = exchange.identity.id;
    if (mode == "closed") {
      return 0;
    }
    if (mode == "timeout") {
      ::pause();
      return 0;
    }
    if (mode == "oversized") {
      const std::array<Byte, 4> prefix{1, 0, 1, 0};
      check(writeDescriptor(STDOUT_FILENO, prefix) == 0);
      continue;
    }
    if (mode == "invalid") {
      channel.send(std::array<Byte, 1>{255});
      continue;
    }
    if (mode == "callback-error" && count == 1) {
      channel.send(tap::Protocol::encodeError(output, event_id, "callback failed"));
      continue;
    }
    if (mode == "stderr") {
      std::array<Byte, 4096> bytes;
      bytes.fill('e');
      for (unsigned index = 0; index < 256; ++index) {
        check(writeDescriptor(STDERR_FILENO, bytes) == 0);
      }
    }

    tap::EffectBatch effects;
    effects.count = 1;
    effects.notifications[0] = {.level = NotificationLevel::info, .duration_ms = 4000, .title = count == 1 ? "first" : "next", .message = "fixture"};
    channel.send(tap::Protocol::encodeEffects(output, mode == "stale" ? event_id + 1 : event_id, effects));
  }
  return 0;
}

static void testRestartWindow() {
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
  testRestartWindow();
  SystemAllocator system;
  BudgetAllocator memory{system, 4 * 1024 * 1024};
  const ExecutablePath executable;
  const std::string executable_path{executable.view()};
  CancellationSignal cancellation;
  CaptureQuota quota{4096};
  std::array<Byte, 4096> output;
  CapturedExchange exchange{memory};
  const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};
  exchange.request = makeOwned<CaptureHalf<decltype(memory)>>(memory, memory, quota, limits, CaptureStart{.key = {1, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "test", .started_at_ms = 1});
  exchange.request->appendHead("GET / HTTP/1.1\r\n\r\n");
  const auto frame = tap::Protocol::encodeExchange(output, {73, 1}, exchange);
  tap::ServiceSpec specification;
  specification.plugin_id = 19;
  specification.generation = 1;
  specification.declared.insert(tap::Capability::proxy_tap);
  specification.declared.insert(tap::Capability::notifications);
  specification.granted = specification.declared;

  for (const auto *mode : {"echo", "callback-error", "stderr"}) {
    tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = mode, .cancellation = cancellation}};
    const auto process = session.processId();
    auto first = session.exchange(specification, 73, frame);
    if (std::string_view{mode} == "callback-error") {
      check(!first);
    } else {
      check(first && first->batch.notifications[0].title == "first");
      check(first->authorized(specification));
      auto stale = specification;
      ++stale.generation;
      check(!first->authorized(stale));
      stale = specification;
      stale.digest[0] ^= 1;
      check(!first->authorized(stale));
    }
    if (std::string_view{mode} == "stderr") {
      check(session.retainedError().size() == tap::Limits::stderr_bytes);
    }
    const auto second = session.exchange(specification, 73, frame);
    check(second && second->batch.notifications[0].title == "next" && session.processId() == process);
  }

  for (const auto *mode : {"closed", "oversized", "invalid", "stale", "timeout", "blocked-write"}) {
    tap::Session session{memory, tap::SessionOptions{.executable = executable_path.c_str(), .entry = mode, .cancellation = cancellation, .timeout = std::chrono::milliseconds{100}}};
    const bool timed = std::string_view{mode} == "timeout" || std::string_view{mode} == "blocked-write";
    bool rejected = false;
    try {
      if (std::string_view{mode} == "blocked-write") {
        SensitiveAllocation large{memory, 1024 * 1024};
        std::ranges::fill(large.bytes(), 0);
        session.exchange(specification, 73, large.bytes());
      } else {
        session.exchange(specification, 73, frame);
      }
    } catch (const SystemError &error) {
      rejected = !timed || error.code() == ETIMEDOUT;
    } catch (const EncodingError &) {
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
    } catch (const SystemError &error) {
      cancelled = error.code() == ECANCELED;
    }
    check(cancelled);
  }
  exchange.request.reset();
  check(memory.liveBytes() == 0 && quota.used() == 0);
}
