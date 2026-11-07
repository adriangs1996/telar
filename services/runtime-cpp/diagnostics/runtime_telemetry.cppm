module;
#include <type_traits>
#include <string>
#include <vector>
#include <mutex>
#include <new>
#include <ghostty/vt.h>
#include <source_location>
#include <stdlib.h>
#include <zlib.h>

#include <atomic>
#include <exception>
#include <cstddef>
#include <cstdint>
#include "telar_base/diagnostics/config.hpp"

#include <limits>
#include <optional>
#include <string_view>

#include <cstring>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <algorithm>
#include <array>
#include <csignal>
#include <cstdio>
#include <limits.h>
#include <sys/stat.h>

#include <concepts>
#include <condition_variable>
#include <pthread.h>

#if (defined(__APPLE__))
#include <mach/mach.h>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <charconv>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <span>
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif

#include <span>
#include <sys/types.h>
#include <chrono>
#include <bit>
#include <stdexcept>
#include <variant>
#include <cassert>
#include <utility>
#include <charconv>
#include <cstdlib>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <tuple>
#include <memory>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>

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
#if (TELAR_DIAGNOSTICS) && (defined(__APPLE__))
#include <mach/mach.h>
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
#if (TELAR_DIAGNOSTICS) && (!(defined(__APPLE__)))
#endif
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
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif

export module telar.runtime.diagnostics.runtime_telemetry;

export import telar.runtime.history.event;


export import telar.platform;


export import telar.runtime.platform.request_worker;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;


#if (!(defined(__APPLE__)))
export import telar.runtime.platform.launch_program;
#endif


export import telar.runtime.exchange_capture.exchange;
export import telar.runtime.proxy.http2_capture_streams;


export import telar.runtime.model.client_layouts;
export import telar.runtime.diagnostics.operation;


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

inline void writeHistorySample(Line &line, const HistoryMetrics &metrics) {
  line.field("history_available", metrics.available);
  line.field("history_sqlite_bytes", metrics.sqlite_bytes);
  line.field("sqlite_open_failures", !metrics.available);
  line.field("history_queue_depth", metrics.queue.depth);
  line.field("history_queue_high_water", metrics.queue.high_water);
  line.field("history_queue_dropped", metrics.queue.dropped);
  line.field("history_queries", metrics.query_submissions);
  line.field("history_query_failures", metrics.query_refusals);
  line.field("sqlite_writes", metrics.writes.timing.count);
  line.field("sqlite_write_failures", metrics.writes.failures);
  line.timing("sqlite_write_avg_us", "sqlite_write_max_us", metrics.writes.timing);
  line.field("sqlite_queries", metrics.queries.timing.count);
  line.field("sqlite_query_failures", metrics.queries.failures);
  line.timing("sqlite_query_avg_us", "sqlite_query_max_us", metrics.queries.timing);
}

}
}

// Interface: diagnostics/log_name.cppm
export {
namespace telar::runtime::diagnostics {

struct LogName {
  enum class Role {
    runtime,
    client
  };

  std::string_view endpoint;
  Role role;
  std::uint32_t process;
  bool rotated;

  inline static std::optional<LogName> parse(std::string_view name) noexcept {
    const bool rotated = name.ends_with(".log.1");
    if (rotated) {
      name.remove_suffix(2);
    }

    if (!name.ends_with(".log")) {
      return std::nullopt;
    }

    name.remove_suffix(4);
    const auto dash = name.rfind('-');
    if (dash == std::string_view::npos) {
      return std::nullopt;
    }

    const auto digits = name.substr(dash + 1);
    if (digits.empty() || digits.front() == '_' || digits.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t process = 0;
    for (const auto character : digits) {
      if (character == '_') {
        continue;
      }

      if (character < '0' || character > '9') {
        return std::nullopt;
      }

      const auto digit = static_cast<std::uint32_t>(character - '0');
      if (process > (std::numeric_limits<std::uint32_t>::max() - digit) / 10) {
        return std::nullopt;
      }

      process = process * 10 + digit;
    }

    if (process == 0) {
      return std::nullopt;
    }

    const auto dot = name.substr(0, dash).rfind('.');
    if (dot == std::string_view::npos) {
      return std::nullopt;
    }

    const auto role = name.substr(dot + 1, dash - dot - 1);
    if (role != "runtime" && role != "client") {
      return std::nullopt;
    }

    return LogName{name.substr(0, dot), role == "runtime" ? Role::runtime : Role::client, process, rotated};
  }
};

}
}

// Interface: diagnostics/log_sink.cppm
export {
namespace telar::runtime::diagnostics {

class LogSink {
public:
  static constexpr std::size_t file_limit = 4 * 1024 * 1024;
  static constexpr std::size_t cleanup_limit = 4096;

  inline explicit LogSink(std::string_view endpoint, pid_t process = ::getpid(), std::size_t limit = file_limit) noexcept
      : limit_(limit) {
    if (endpoint.empty() || endpoint.front() != '/' || endpoint.contains('\0') || endpoint.size() >= PATH_MAX || process <= 0) {
      return;
    }

    const auto length = std::snprintf(path_.data(), path_.size(), "%.*s.runtime-%d.log", static_cast<int>(endpoint.size()), endpoint.data(), process);
    if (length < 0 || static_cast<std::size_t>(length) >= path_.size()) {
      return;
    }

    path_length_ = static_cast<std::size_t>(length);
    open();
  }

  inline bool available() const noexcept {
    return static_cast<bool>(file_);
  }

  inline std::string_view path() const noexcept {
    return {path_.data(), path_length_};
  }

  inline void disable() noexcept {
    file_.reset();
  }

  inline bool write(std::string_view bytes) noexcept {
    if (!file_) {
      return false;
    }

    if (written_ != 0 && (written_ > limit_ || bytes.size() > limit_ - written_)) {
      if (!rotate()) {
        disable();
        return false;
      }
    }

    while (!bytes.empty()) {
      const auto count = ::write(file_.get(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }

      if (count <= 0) {
        disable();
        return false;
      }

      written_ += static_cast<std::size_t>(count);
      bytes.remove_prefix(static_cast<std::size_t>(count));
    }

    return true;
  }

  inline static void removeOrphans(std::string_view endpoint) noexcept {
    const auto slash = endpoint.rfind('/');
    if (slash == std::string_view::npos || endpoint.front() != '/' || endpoint.contains('\0') || slash >= PATH_MAX) {
      return;
    }

    std::array<char, PATH_MAX> directory_path;
    const auto directory_length = std::max<std::size_t>(1, slash);
    std::copy_n(endpoint.begin(), directory_length, directory_path.begin());
    directory_path[directory_length] = '\0';

    try {
      DirectoryStream directory{FileDescriptor{::open(directory_path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC)}};
      for (std::size_t scanned = 0; scanned < cleanup_limit; ++scanned) {
        const auto *entry = directory.next();
        if (entry == nullptr) {
          break;
        }

        const auto name = LogName::parse({entry->d_name, std::strlen(entry->d_name)});
        if (!name || (name->endpoint != endpoint.substr(slash + 1) && !name->endpoint.ends_with(".sock"))) {
          continue;
        }

        struct stat status;
        if (::fstatat(directory.descriptor(), entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode)) {
          continue;
        }

        if (name->process <= static_cast<std::uint32_t>(std::numeric_limits<pid_t>::max())) {
          const auto process = static_cast<pid_t>(name->process);
          if (::kill(process, 0) == 0 || errno != ESRCH) {
            continue;
          }
        }

        ::unlinkat(directory.descriptor(), entry->d_name, 0);
      }
    } catch (...) {
    }
  }

private:
  inline void open() noexcept {
    file_.reset(::open(path_.data(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  }

  inline bool rotate() noexcept {
    std::array<char, PATH_MAX + 2> previous;
    std::copy_n(path_.begin(), path_length_, previous.begin());
    std::copy_n(".1", 3, previous.begin() + path_length_);
    file_.reset();
    if (::rename(path_.data(), previous.data()) != 0) {
      return false;
    }

    open();
    written_ = 0;
    return available();
  }

  FileDescriptor file_;
  std::array<char, PATH_MAX> path_;
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

  inline explicit LogWriter(std::string_view endpoint) noexcept
      : sink_(endpoint) {}

  inline Result observe(const Request &line) noexcept {
    return sink_.write(line);
  }

  inline void stop() noexcept {}

  inline bool available() const noexcept {
    return sink_.available();
  }

private:
  LogSink sink_;
};

class LogSession {
public:
  inline explicit LogSession(std::string_view endpoint) noexcept
      : writer_(prepare(endpoint)) {
    if (writer_.available()) {
      try {
        worker_.emplace(writer_);
      } catch (...) {
      }
    }
  }

  inline ~LogSession() {
    if (worker_) {
      worker_->wait([](bool) {});
    }
  }

  template <typename Format>
  inline void sample(Format &&format) noexcept {
    if (!worker_) {
      return;
    }

    worker_->collect([this](bool written) {
      pending_ = false;
      failed_ = !written;
    });
    if (pending_ || failed_) {
      return;
    }

    try {
      line_.reset();
      format(line_);
      pending_ = worker_->submit(line_.finish());
    } catch (...) {
    }
  }

private:
  inline static std::string_view prepare(std::string_view endpoint) noexcept {
    LogSink::removeOrphans(endpoint);
    return endpoint;
  }

  LogWriter writer_;
  Line line_;
  std::optional<ObservationWorker<LogWriter>> worker_;
  bool pending_ = false;
  bool failed_ = false;
};

}
}

// Interface: diagnostics/memory_sample.cppm
export {
#if defined(__APPLE__)
#else
#endif

namespace telar::runtime::diagnostics {

inline std::uint64_t residentBytes() noexcept {
#if defined(__APPLE__)
  task_vm_info_data_t information{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (::task_info(::mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&information), &count) != KERN_SUCCESS) {
    return 0;
  }

  return information.resident_size;
#else
  std::array<char, 256> buffer;
  const auto bytes = ProcDirectory{::getpid()}.read("statm", buffer);
  if (!bytes) {
    return 0;
  }
  const auto separator = bytes->find(' ');
  if (separator == std::string_view::npos) {
    return 0;
  }

  std::uint64_t pages = 0;
  const auto resident = bytes->substr(separator + 1);
  const auto parsed = std::from_chars(resident.data(), resident.data() + resident.size(), pages);
  const auto page_size = ::sysconf(_SC_PAGESIZE);
  return parsed.ec == std::errc{} && page_size > 0 ? pages * static_cast<std::uint64_t>(page_size) : 0;
#endif
}

inline void writeMemorySample(Line &line, const AllocationStatistics &statistics) {
  line.field("heap_live_bytes", statistics.live_bytes);
  line.field("heap_live_allocs", statistics.live_allocations);
  line.field("heap_allocs", statistics.total.count);
  line.field("heap_alloc_bytes", statistics.total.bytes);
  const auto &interactive = statistics.paths[static_cast<std::size_t>(AllocationPath::interactive)];
  const auto &terminal = statistics.interactive_terminal;
  line.field("interactive_allocs", interactive.count);
  line.field("interactive_alloc_bytes", interactive.bytes);
  line.field("interactive_vt_allocs", terminal.count);
  line.field("interactive_vt_alloc_bytes", terminal.bytes);
  line.field("interactive_telar_allocs", interactive.count - terminal.count);
  line.field("interactive_telar_alloc_bytes", interactive.bytes - terminal.bytes);

  const auto &media = statistics.paths[static_cast<std::size_t>(AllocationPath::media)];
  line.field("media_allocs", media.count);
  line.field("media_alloc_bytes", media.bytes);
  const auto &observation = statistics.paths[static_cast<std::size_t>(AllocationPath::observation)];
  line.field("observation_allocs", observation.count);
  line.field("observation_alloc_bytes", observation.bytes);
  const auto &other = statistics.paths[static_cast<std::size_t>(AllocationPath::other)];
  line.field("other_allocs", other.count);
  line.field("other_alloc_bytes", other.bytes);
}

}
}

// Interface: diagnostics/proxy_sample.cppm
export {
namespace telar::runtime::diagnostics {

inline void writeProxySample(Line &line, const ProxyMetrics &metrics) {
  line.field("proxy_active_connections", metrics.active_connections);
  line.field("proxy_connection_limit_drops", metrics.connection_limit_drops);
  line.field("proxy_rejected_connections", metrics.read(ProxyCounter::rejected_connection));
  line.field("proxy_invalid_authorization_rejections", metrics.read(ProxyCounter::invalid_authorization_rejection));
  line.field("proxy_unknown_credential_rejections", metrics.read(ProxyCounter::unknown_credential_rejection));
  line.field("proxy_h2_decode_failures", metrics.read(ProxyCounter::h2_decode_failure));
  line.field("proxy_passthrough_connections", metrics.read(ProxyCounter::passthrough_connection));
  line.field("proxy_anonymous_tunnels", metrics.read(ProxyCounter::anonymous_tunnel));
  line.field("proxy_upstream_connect_failures", metrics.read(ProxyCounter::upstream_connect_failure));
  line.field("proxy_tls_context_failures", metrics.read(ProxyCounter::tls_context_failure));
  line.field("proxy_tls_upstream_handshake_failures", metrics.read(ProxyCounter::tls_upstream_handshake_failure));
  line.field("proxy_tls_downstream_handshake_failures", metrics.read(ProxyCounter::tls_downstream_handshake_failure));
  line.field("proxy_tls_mint_failures", metrics.read(ProxyCounter::tls_mint_failure));
}

inline void writeCaptureSample(Line &line, const CaptureMetrics &metrics) {
  line.field("proxy_capture_started", metrics.started);
  line.field("proxy_capture_truncated", metrics.truncated);
  line.field("proxy_capture_skipped_quota", metrics.skipped);
  line.field("proxy_capture_dropped_queue", metrics.dropped_queue);
  line.field("proxy_capture_decode_failed", metrics.decode_failed);
  line.field("proxy_capture_queue_depth", metrics.queued);
  line.field("proxy_capture_queue_high_water", metrics.queue_high_water);
}

}
}

// Interface: diagnostics/runtime_sample.cppm
export {
namespace telar::runtime::diagnostics {

template <Allocator Memory>
void writeRuntimeSample(Line &line, RuntimeModel<Memory> &model) {
  std::size_t tabs = 0;
  std::size_t attachments = 0;
  std::size_t outstanding_frames = 0;
  std::size_t dirty_panes = 0;
  std::size_t response_queue_bytes = 0;
  std::size_t response_queue_depth = 0;
  std::size_t response_queue_high_water = 0;
  std::uint64_t response_queue_dropped = 0;
  std::size_t pane_input_queue_depth = 0;
  std::uint64_t pane_input_dropped_bytes = 0;
  std::size_t pty_response_queue_depth = 0;
  std::size_t pty_response_queue_bytes = 0;
  std::uint64_t pty_response_dropped = 0;
  std::size_t pane_media_used = 0;
  MediaQueue media_queue;
  GraphicsStorageSnapshot graphics_storage;
  TerminalStorageSnapshot terminal_storage;
  for (const auto *workspace : model.workspaces.items()) {
    if (workspace != nullptr) {
      tabs += workspace->tabs.size();
    }
  }

  for (const auto *client : model.clients.items()) {
    if (client == nullptr) {
      continue;
    }

    attachments += client->attachments.size();
    response_queue_bytes += client->connection.queuedBytes();
    response_queue_depth += client->connection.responseDepth();
    response_queue_high_water += client->connection.responseHighWater();
    accumulate(response_queue_dropped, client->connection.droppedResponses());
    for (const auto &attachment : client->attachments) {
      outstanding_frames += attachment->frames.waitingForAck();
      accumulate(graphics_storage.transfer_bytes, attachment->graphics.transferBytes());
    }
  }

  for (auto *pane : model.panes.items()) {
    if (pane == nullptr) {
      continue;
    }

    dirty_panes += pane->terminal.dirty();
    pane_input_queue_depth += pane->input.size();
    accumulate(pane_input_dropped_bytes, pane->input_dropped_bytes);
    const auto responses = pane->pty_responses->snapshot();
    pty_response_queue_depth += responses.messages;
    pty_response_queue_bytes += responses.bytes;
    accumulate(pty_response_dropped, responses.dropped);
    pane_media_used += pane->media->usedBytes();
    media_queue.merge(pane->media->queueMetrics());
    graphics_storage.merge(pane->media->storageMetrics());
    terminal_storage.merge(pane->terminal.storageMetrics());
  }

  line.field("client_count", model.clients.size());
  line.field("workspace_count", model.workspaces.size());
  line.field("tab_count", tabs);
  line.field("pane_count", model.panes.size());
  line.field("attachment_count", attachments);
  line.field("outstanding_frames", outstanding_frames);
  line.field("dirty_panes", dirty_panes);
  line.field("response_queue_bytes", response_queue_bytes);
  line.field("response_queue_depth", response_queue_depth);
  line.field("response_queue_high_water", response_queue_high_water);
  line.field("response_queue_dropped", response_queue_dropped);
  line.field("pane_input_queue_depth", pane_input_queue_depth);
  line.field("pane_input_dropped_bytes", pane_input_dropped_bytes);
  line.field("pty_response_queue_depth", pty_response_queue_depth);
  line.field("pty_response_queue_bytes", pty_response_queue_bytes);
  line.field("pty_response_dropped", pty_response_dropped);
  line.field("graphics_budget_used", model.media_budget.used());
  line.field("pane_media_used", pane_media_used);
  media_queue.write(line);
  graphics_storage.write(line);
  terminal_storage.write(line);
}

}
}

// Interface: diagnostics/runtime_telemetry.cppm
export {
#if TELAR_DIAGNOSTICS
#endif

namespace telar::runtime::diagnostics {

class RuntimeTelemetry {
public:
#if TELAR_DIAGNOSTICS
  using Clock = std::chrono::steady_clock;
  static constexpr auto sample_interval = std::chrono::seconds{1};

  inline explicit RuntimeTelemetry(std::string_view endpoint, const ProxyStatus &proxy) noexcept
      : session_(endpoint), proxy_(proxy) {}

  template <Allocator Memory, typename Captures, typename Background>
  inline std::chrono::nanoseconds tick(RuntimeModel<Memory> &model, Memory &memory, const Captures &captures, const Background &background, Clock::time_point now) noexcept {
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
  inline explicit RuntimeTelemetry(std::string_view endpoint, const ProxyStatus &) noexcept {
    LogSink::removeOrphans(endpoint);
  }
#endif
};

}
}
