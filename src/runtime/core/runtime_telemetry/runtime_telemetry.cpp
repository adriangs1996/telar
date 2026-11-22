module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.core.runtime_telemetry;

import telar.sys.process;
import telar.base.text;
import telar.platform.fs;
import telar.runtime.diagnostics.operation;
import telar.base.ds;
#ifdef __APPLE__
import telar.sys.apple;
#else
import telar.runtime.host.proc_file;
#endif

namespace telar::runtime::diagnostics {

  namespace {

    // A log is an orphan once the process that wrote it is gone; a process number no pid_t holds names none.
    bool writerAlive(std::uint32_t process) noexcept {
      if (process > static_cast<std::uint32_t>(std::numeric_limits<pid_t>::max())) {
        return false;
      }

      return ::kill(static_cast<pid_t>(process), 0) == 0 || sys::lastError() != ESRCH;
    }

    // Removes the entry when it is a regular log file of this endpoint, or of any socket, whose writer is gone.
    void removeIfOrphan(int directory, const dirent& entry, std::string_view endpoint_name) noexcept {
      const std::span<const char> name_bytes{entry.d_name};
      const auto name = LogName::parse({name_bytes.begin(), std::ranges::find(name_bytes, '\0')});
      if (!name || (name->endpoint != endpoint_name && !name->endpoint.ends_with(".sock"))) {
        return;
      }

      struct stat status{};
      if (::fstatat(directory, name_bytes.data(), &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode)) {
        return;
      }

      if (!writerAlive(name->process)) {
        ::unlinkat(directory, name_bytes.data(), 0);
      }
    }

  }

  void writeHistorySample(Line& line, const HistoryMetrics& metrics) {
    line.field("history_available", static_cast<std::uint64_t>(metrics.available));
    line.field("history_sqlite_bytes", metrics.sqlite_bytes);
    line.field("sqlite_open_failures", static_cast<std::uint64_t>(!metrics.available));
    line.field("history_queue_depth", metrics.queue.depth);
    line.field("history_queue_high_water", metrics.queue.high_water);
    line.field("history_queue_dropped", metrics.queue.dropped);
    line.field("history_queries", metrics.query_submissions);
    line.field("history_query_failures", metrics.query_refusals);
    line.field("sqlite_writes", metrics.writes.timing.count);
    line.field("sqlite_write_failures", metrics.writes.failures);
    line.timing({.average = "sqlite_write_avg_us", .maximum = "sqlite_write_max_us"}, metrics.writes.timing);
    line.field("sqlite_queries", metrics.queries.timing.count);
    line.field("sqlite_query_failures", metrics.queries.failures);
    line.timing({.average = "sqlite_query_avg_us", .maximum = "sqlite_query_max_us"}, metrics.queries.timing);
  }

  ds::Option<LogName> LogName::parse(std::string_view name) noexcept {
    const bool rotated = name.ends_with(".log.1");
    if (rotated) {
      name.remove_suffix(2);
    }

    if (!name.ends_with(".log")) {
      return ds::none;
    }

    name.remove_suffix(4);
    const auto dash = name.rfind('-');
    if (dash == std::string_view::npos) {
      return ds::none;
    }

    // Each cut below sits at a position rfind found inside the name, so none can fall outside it.
    auto digits = name;

    digits.remove_prefix(dash + 1);
    name.remove_suffix(name.size() - dash);

    const auto process = unsignedDecimal<std::uint32_t>(digits).valueOr(0);
    if (process == 0) {
      return ds::none;
    }

    const auto dot = name.rfind('.');
    if (dot == std::string_view::npos) {
      return ds::none;
    }

    auto role = name;

    role.remove_prefix(dot + 1);
    name.remove_suffix(name.size() - dot);
    if (role != "runtime" && role != "client") {
      return ds::none;
    }

    return LogName{.endpoint = name, .role = role == "runtime" ? Role::runtime : Role::client, .process = process, .rotated = rotated};
  }

  LogSink::LogSink(std::string_view endpoint, LogFile file) noexcept
      : limit_(file.limit) {
    const auto process = file.process;
    if (endpoint.empty() || endpoint.front() != '/' || endpoint.contains('\0') || endpoint.size() >= PATH_MAX || process <= 0) {
      return;
    }

    // The path is "<endpoint>.runtime-<process>.log"; one that does not fit with the terminator open needs is
    // refused, as a truncated one would name another file.
    constexpr std::string_view infix{".runtime-"};
    constexpr std::string_view suffix{".log"};
    const std::span<char> path{path_.viewMut()};
    const auto digits_at = endpoint.size() + infix.size();
    if (digits_at >= path.size()) {
      return;
    }

    std::ranges::copy(infix, std::ranges::copy(endpoint, path.begin()).out);

    const auto digits = path.subspan(digits_at);
    const auto converted = std::to_chars(digits.data(), std::to_address(digits.end()), process);
    const auto suffix_at = digits_at + static_cast<std::size_t>(converted.ptr - digits.data());
    if (converted.ec == std::errc::value_too_large || suffix_at + suffix.size() >= path.size()) {
      return;
    }

    std::ranges::copy(suffix, path.subspan(suffix_at).begin());
    path_length_ = suffix_at + suffix.size();
    path_.atMut(path_length_) = '\0';
    open();
  }

  bool LogSink::available() const noexcept {
    return static_cast<bool>(file_);
  }

  std::string_view LogSink::path() const noexcept {
    return {path_.data(), path_length_};
  }

  void LogSink::disable() noexcept {
    file_.reset();
  }

  bool LogSink::write(std::string_view bytes) noexcept {
    if (!file_) {
      return false;
    }

    if (written_ != 0 && (written_ > limit_ || bytes.size() > limit_ - written_) && !rotate()) {
      disable();
      return false;
    }

    while (!bytes.empty()) {
      const auto count = ::write(file_.get(), bytes.data(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
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

  void LogSink::removeOrphans(std::string_view endpoint) noexcept {
    const auto slash = endpoint.rfind('/');
    if (slash == std::string_view::npos || endpoint.front() != '/' || endpoint.contains('\0') || slash >= PATH_MAX) {
      return;
    }

    ds::Array<char, PATH_MAX> directory_path{};
    const auto directory_length = std::max<std::size_t>(1, slash);

    std::copy_n(endpoint.begin(), directory_length, directory_path.dataMut());
    directory_path.atMut(directory_length) = '\0';

    try {
      DirectoryStream directory{FileDescriptor{::open(directory_path.data(), combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC))}}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      const auto endpoint_name = endpoint.substr(slash + 1);

      for (std::size_t scanned = 0; scanned < cleanup_limit; ++scanned) {
        const auto* entry = directory.next();
        if (entry == nullptr) {
          break;
        }

        removeIfOrphan(directory.descriptor(), *entry, endpoint_name);
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): removing stale logs is best effort; a directory that cannot be read keeps them
    }
  }

  void LogSink::open() noexcept {
    constexpr mode_t owner_read_write = 0600;

    file_.reset(::open(path_.data(), combineFlags(O_WRONLY, O_CREAT, O_EXCL, O_CLOEXEC, O_NOFOLLOW), owner_read_write)); // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
  }

  bool LogSink::rotate() noexcept {
    constexpr std::string_view rotated_suffix{".1\0", 3};
    ds::Array<char, PATH_MAX + 2> previous{};

    std::ranges::copy(rotated_suffix, std::ranges::copy(path(), previous.dataMut()).out);
    file_.reset();
    if (::rename(path_.data(), previous.data()) != 0) {
      return false;
    }

    open();
    written_ = 0;
    return available();
  }

  LogWriter::LogWriter(std::string_view endpoint) noexcept
      : sink_(endpoint) {}

  LogWriter::Result LogWriter::observe(const Request& line) noexcept {
    return sink_.write(line);
  }

  void LogWriter::stop() noexcept {}

  bool LogWriter::available() const noexcept {
    return sink_.available();
  }

  LogSession::LogSession(std::string_view endpoint) noexcept {
    LogWriter writer{prepare(endpoint)};
    if (writer.available()) {
      try {
        worker_.emplace(std::in_place, std::move(writer));
      } catch (...) { // NOLINT(bugprone-empty-catch): without a worker the session writes no samples, as when the log cannot open
      }
    }
  }

  LogSession::~LogSession() {
    if (worker_) {
      worker_.getMut().wait([](bool) {});
    }
  }

  std::string_view LogSession::prepare(std::string_view endpoint) noexcept {
    LogSink::removeOrphans(endpoint);
    return endpoint;
  }

  std::uint64_t residentBytes() noexcept {
#ifdef __APPLE__
    task_vm_info_data_t information{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (::task_info(::mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&information), &count) != KERN_SUCCESS) { // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): task_info returns every flavor through an integer array
      return 0;
    }

    return information.resident_size;
#else
    ds::Array<char, 256> buffer;
    const auto bytes = ProcDirectory{::getpid()}.read("statm", buffer.viewMut());
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

  void writeMemorySample(Line& line, const AllocationStatistics& statistics) {
    line.field("heap_live_bytes", statistics.live_bytes);
    line.field("heap_live_allocs", statistics.live_allocations);
    line.field("heap_allocs", statistics.total.count);
    line.field("heap_alloc_bytes", statistics.total.bytes);
    const auto& interactive = statistics.paths[static_cast<std::size_t>(AllocationPath::interactive)];
    const auto& terminal = statistics.interactive_terminal;

    line.field("interactive_allocs", interactive.count);
    line.field("interactive_alloc_bytes", interactive.bytes);
    line.field("interactive_vt_allocs", terminal.count);
    line.field("interactive_vt_alloc_bytes", terminal.bytes);
    line.field("interactive_telar_allocs", interactive.count - terminal.count);
    line.field("interactive_telar_alloc_bytes", interactive.bytes - terminal.bytes);

    const auto& media = statistics.paths[static_cast<std::size_t>(AllocationPath::media)];

    line.field("media_allocs", media.count);
    line.field("media_alloc_bytes", media.bytes);
    const auto& observation = statistics.paths[static_cast<std::size_t>(AllocationPath::observation)];

    line.field("observation_allocs", observation.count);
    line.field("observation_alloc_bytes", observation.bytes);
    const auto& other = statistics.paths[static_cast<std::size_t>(AllocationPath::other)];

    line.field("other_allocs", other.count);
    line.field("other_alloc_bytes", other.bytes);
  }

  void writeProxySample(Line& line, const ProxyMetrics& metrics) {
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

  void writeCaptureSample(Line& line, const CaptureMetrics& metrics) {
    line.field("proxy_capture_started", metrics.started);
    line.field("proxy_capture_truncated", metrics.truncated);
    line.field("proxy_capture_skipped_quota", metrics.skipped);
    line.field("proxy_capture_dropped_queue", metrics.dropped_queue);
    line.field("proxy_capture_decode_failed", metrics.decode_failed);
    line.field("proxy_capture_queue_depth", metrics.queued);
    line.field("proxy_capture_queue_high_water", metrics.queue_high_water);
  }

  // The sample reads counters that only a diagnostics build keeps.
#if TELAR_DIAGNOSTICS
  void writeRuntimeSample(Line& line, RuntimeModel& model, const ClientStore& clients) { // NOLINT(misc-const-correctness): each pane's media is sampled through its shared handle, a mutation tbc sees through the model
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

    for (const auto* workspace : model.workspaces.items()) {
      if (workspace != nullptr) {
        tabs += workspace->tabs.size();
      }
    }

    for (const auto* client : clients.items()) {
      if (client == nullptr) {
        continue;
      }

      attachments += client->attachments.size();
      response_queue_bytes += client->connection.queuedBytes();
      response_queue_depth += client->connection.responseDepth();
      response_queue_high_water += client->connection.responseHighWater();
      accumulate(response_queue_dropped, client->connection.droppedResponses());
      for (const auto& attachment : client->attachments) {
        outstanding_frames += static_cast<std::size_t>(attachment->frames.waitingForAck());
        accumulate(graphics_storage.transfer_bytes, attachment->graphics.transferBytes());
      }
    }

    for (auto* stored : model.panes.items()) {
      // What is summed here is a terminal's: its screen, its queues and its media.
      const auto pane = asTerminal(stored); // NOLINT(misc-const-correctness): the pane's media is sampled through its shared handle, a mutation tbc sees through the pane
      if (!pane) {
        continue;
      }

      dirty_panes += static_cast<std::size_t>(pane->body.terminal.dirty());
      pane_input_queue_depth += pane->body.input.size();
      accumulate(pane_input_dropped_bytes, pane->body.input_dropped_bytes);
      const auto responses = pane->body.pty_responses->snapshot();

      pty_response_queue_depth += responses.messages;
      pty_response_queue_bytes += responses.bytes;
      accumulate(pty_response_dropped, responses.dropped);
      pane_media_used += pane->body.media->usedBytes();
      media_queue.merge(pane->body.media->queueMetrics());
      graphics_storage.merge(pane->body.media->storageMetrics());
      terminal_storage.merge(pane->body.terminal.storageMetrics());
    }

    line.field("client_count", clients.size());
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
#endif

#if TELAR_DIAGNOSTICS
  RuntimeTelemetry::RuntimeTelemetry(std::string_view endpoint, ProxyStatus proxy) noexcept
      : session_(endpoint),
        proxy_(proxy) {}
#else
  RuntimeTelemetry::RuntimeTelemetry(std::string_view endpoint, ProxyStatus) noexcept {
    LogSink::removeOrphans(endpoint);
  }
#endif

}
