#pragma once

#include "config.hpp"
#include "log_sink.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <string_view>

#if TELAR_DIAGNOSTICS
#include "history_sample.hpp"
#include "log_writer.hpp"
#include "memory_sample.hpp"
#include "proxy_sample.hpp"
#include "runtime_sample.hpp"
#endif

namespace telar::runtime::diagnostics {

class RuntimeTelemetry {
public:
#if TELAR_DIAGNOSTICS
  using Clock = std::chrono::steady_clock;
  static constexpr auto sample_interval = std::chrono::seconds{1};

  explicit RuntimeTelemetry(std::string_view endpoint, const ProxyStatus &proxy) noexcept
      : session_(endpoint), proxy_(proxy) {}

  template <Allocator Memory, typename Captures, typename Background>
  std::chrono::nanoseconds tick(RuntimeModel<Memory> &model, Memory &memory, const Captures &captures, const Background &background, Clock::time_point now) noexcept {
    if (now < next_sample_) {
      return next_sample_ - now;
    }

    next_sample_ = now + sample_interval;
    session_.sample([&](Line &line) {
      line.field("ts_ms", std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count());
      line.field("uptime_ms", std::chrono::duration_cast<std::chrono::milliseconds>(now - started_).count());
      line.literal("role", "\"runtime\"");
      writeRuntimeSample(line, model);
      model.metrics.write(line);
      line.field("proxy_active", proxy_.active);
      line.field("proxy_port", std::optional<std::uint64_t>{proxy_.port});
      line.field("proxy_preferred_port", std::optional<std::uint64_t>{proxy_.preferred_port});
      if constexpr (requires { captures.captureMetrics(); }) {
        writeCaptureSample(line, captures.captureMetrics());
      }

      if constexpr (requires { captures.proxyMetrics(); }) {
        writeProxySample(line, captures.proxyMetrics());
      }

      if constexpr (requires { background.historyMetrics(); }) {
        writeHistorySample(line, background.historyMetrics());
      }

      line.field("rss_bytes", residentBytes());
      if constexpr (requires { memory.statistics(); }) {
        writeMemorySample(line, memory.statistics());
      }
    });

    return next_sample_ - now;
  }

private:
  LogSession session_;
  ProxyStatus proxy_;
  Clock::time_point started_ = Clock::now();
  Clock::time_point next_sample_ = started_ + sample_interval;
#else
  explicit RuntimeTelemetry(std::string_view endpoint, const ProxyStatus &) noexcept {
    LogSink::removeOrphans(endpoint);
  }
#endif
};

}
