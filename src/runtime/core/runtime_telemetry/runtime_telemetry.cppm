module;
#include "tbc/annotations.hpp"

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.core.runtime_telemetry;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.history.event;

import telar.runtime.workers.request_worker;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;

import telar.runtime.traffic.tap.exchange;
import telar.runtime.traffic.proxy.http2_capture_streams;

import telar.runtime.core.model.client_layouts;
import telar.base.memory.allocators;
import telar.base.ds;

#if (TELAR_DIAGNOSTICS)

#endif
#if (TELAR_DIAGNOSTICS)

#endif
#if (TELAR_DIAGNOSTICS)

#endif
#if (TELAR_DIAGNOSTICS)

#endif
#if (TELAR_DIAGNOSTICS)

#endif

// Interface: diagnostics/history_sample.cppm
export {
  namespace telar::runtime::diagnostics {

    void writeHistorySample(Line& line, const HistoryMetrics& metrics);

  }
}

// Interface: diagnostics/log_name.cppm
export {
  namespace telar::runtime::diagnostics {

    struct LogName {
      enum class Role : std::uint8_t {
        runtime,
        client,
      };

      std::string_view endpoint;
      Role role;
      std::uint32_t process;
      bool rotated;

      static ds::Option<LogName> parse(std::string_view name) noexcept;
    };

  }
}

// Interface: diagnostics/log_sink.cppm
export {
  namespace telar::runtime::diagnostics {

    // The file a log sink writes: the process it is named after, and the bytes it holds before it
    // rotates.
    struct LogFile {
      static constexpr std::size_t default_limit = std::size_t{4} * 1024 * 1024;

      pid_t process = ::getpid();
      std::size_t limit = default_limit;
    };

    class LogSink {
    public:
      static constexpr std::size_t cleanup_limit = 4096;

      explicit LogSink(std::string_view endpoint, LogFile file = {}) noexcept;

      [[nodiscard]] bool available() const noexcept;

      [[nodiscard]] std::string_view path() const noexcept;

      void disable() noexcept;

      bool write(std::string_view bytes) noexcept;

      static void removeOrphans(std::string_view endpoint) noexcept;

    private:
      void open() noexcept;

      bool rotate() noexcept;

      FileDescriptor file_;
      ds::Array<char, PATH_MAX> path_{};
      std::size_t path_length_ = 0;
      std::size_t written_ = 0;
      std::size_t limit_;
    };

  }
}

// Interface: diagnostics/log_writer.cppm
export {
  namespace telar::runtime::diagnostics {

    class LogWriter {
    public:
      using Request = std::string_view;
      using Result = bool;

      explicit LogWriter(std::string_view endpoint) noexcept;

      Result observe(const Request& line) noexcept;

      void stop() noexcept;

      [[nodiscard]] bool available() const noexcept;

    private:
      LogSink sink_;
    };

    class LogSession {
    public:
      explicit LogSession(std::string_view endpoint) noexcept;

      ~LogSession();

      LogSession(const LogSession&) = delete;
      LogSession& operator=(const LogSession&) = delete;
      LogSession(LogSession&&) = delete;
      LogSession& operator=(LogSession&&) = delete;

      // Kept here: the format is the caller's callable, an open set no unit can instantiate ahead.
      template <typename Format>
      TBC_GENERIC inline void sample(Format&& format) noexcept {
        if (!worker_) {
          return;
        }

        worker_.getMut().collect([this](bool written) {
          pending_ = false;
          failed_ = !written;
        });

        if (pending_ || failed_) {
          return;
        }

        try {
          line_.reset();
          std::forward<Format>(format)(line_);
          pending_ = worker_.getMut().submit(line_.finish());
        } catch (...) { // NOLINT(bugprone-empty-catch): a sample that cannot be formatted is skipped; the next tick writes a fresh one
        }
      }

    private:
      static std::string_view prepare(std::string_view endpoint) noexcept;

      Line line_;
      // The worker writes the line above until its result is collected, so the session stays put.
      tbc::val_self<ds::Option<ObservationWorker<LogWriter>>> worker_;
      bool pending_ = false;
      bool failed_ = false;
    };

  }
}

// Interface: diagnostics/memory_sample.cppm
export {
#ifdef __APPLE__
#else
#endif

  namespace telar::runtime::diagnostics {

    std::uint64_t residentBytes() noexcept;

    void writeMemorySample(Line& line, const AllocationStatistics& statistics);

  }
}

// Interface: diagnostics/proxy_sample.cppm
export {
  namespace telar::runtime::diagnostics {

    void writeProxySample(Line& line, const ProxyMetrics& metrics);

    void writeCaptureSample(Line& line, const CaptureMetrics& metrics);

  }
}

// Interface: diagnostics/runtime_sample.cppm
export {
  namespace telar::runtime::diagnostics {

    // The sample reads counters that only a diagnostics build keeps.
#if TELAR_DIAGNOSTICS
    void writeRuntimeSample(Line& line, RuntimeModel& model, const ClientStore& clients);
#endif

  }
}

// Interface: diagnostics/runtime_telemetry.cppm
export {
#if TELAR_DIAGNOSTICS
#endif

  namespace telar::runtime::diagnostics {

    // The runtime's services a sample reads.
    template <typename Captures, typename Background>
    struct TelemetryServices {
      const Captures& captures;
      const Background& background;
    };

    class RuntimeTelemetry {
    public:
#if TELAR_DIAGNOSTICS
      using Clock = std::chrono::steady_clock;
      static constexpr auto sample_interval = std::chrono::seconds{1};

      explicit RuntimeTelemetry(std::string_view endpoint, ProxyStatus proxy) noexcept;

      // Kept here: Captures and Background are the runtime's services, from modules that import this one.
      template <typename Captures, typename Background>
      TBC_GENERIC inline std::chrono::nanoseconds tick(RuntimeModel& model, const ClientStore& clients, ConcurrentMemory& memory, TelemetryServices<Captures, Background> services, Clock::time_point now) noexcept {
        if (now < next_sample_) {
          return next_sample_ - now;
        }

        next_sample_ = now + sample_interval;
        session_.sample([&](Line& line) {
          line.field("ts_ms", static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count()));
          line.field("uptime_ms", static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(now - started_).count()));
          line.literal("role", RawJson{.text = "\"runtime\""});
          writeRuntimeSample(line, model, clients);
          model.metrics.write(line);
          line.field("proxy_active", proxy_.active);
          line.field("proxy_port", ds::Option<std::uint64_t>{proxy_.port});
          line.field("proxy_preferred_port", ds::Option<std::uint64_t>{proxy_.preferred_port});
          if constexpr (requires { services.captures.captureMetrics(); }) {
            writeCaptureSample(line, services.captures.captureMetrics());
          }

          if constexpr (requires { services.captures.proxyMetrics(); }) {
            writeProxySample(line, services.captures.proxyMetrics());
          }

          if constexpr (requires { services.background.historyMetrics(); }) {
            writeHistorySample(line, services.background.historyMetrics());
          }

          line.field("rss_bytes", residentBytes());
          if constexpr (requires { memory.statistics(); }) {
            if (const ds::Option<AllocationStatistics> statistics = memory.statistics()) {
              writeMemorySample(line, *statistics);
            }
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
      explicit RuntimeTelemetry(std::string_view endpoint, ProxyStatus) noexcept;
#endif
    };

  }
}
