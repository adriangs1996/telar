module;
#include "telar_platform/trace_macro.hpp"
#include <new>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <cstdint>


#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cstddef>


#include <sqlite3.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>

export module telar.runtime.agents.snapshot;

import std;

export import telar.config;


export import telar.runtime.platform.process_probe;
export import telar.runtime.agents.description_generator;


export import telar.client;


export import telar.runtime.history.store;

export import telar.base.text;
export import telar.platform;


export import telar.runtime.model.client_layouts;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: agents/evidence_state.cppm
export {
namespace telar::runtime {

class AgentEvidenceState {
public:
  inline AgentProvider provider() const noexcept {
    return process ? process->provider : screen ? screen->provider
                                                : AgentProvider::unknown;
  }

  inline bool accepts(AgentProvider incoming) const noexcept {
    const auto running = process ? process->provider : reporter;
    return incoming == AgentProvider::unknown || running == AgentProvider::unknown || running == incoming;
  }

  inline void claim(AgentProvider incoming) noexcept {
    if (!process && incoming != AgentProvider::unknown) {
      reporter = incoming;
    }
  }

  inline bool applyReport(const ReportAgent &incoming, ObservationTime now) {
    if (incoming.provider != AgentProvider::unknown) {
      hooks_seen = true;
    }

    if (report && now.before(report->observed)) {
      return false;
    }

    if (incoming.state == AgentReportState::continuing) {
      if (!report || report->status != AgentStatus::working || report_state == AgentReportState::settling || report->expired(now.milliseconds) || report->expires_at - now.milliseconds > AgentEvidence::renewal_margin.count()) {
        return false;
      }

      report->expires_at = now.milliseconds + AgentEvidence::report_working_expiry.count();
      return true;
    }

    const bool waiting = report && report_state == AgentReportState::waiting && !report->expired(now.milliseconds);
    if ((incoming.state == AgentReportState::idle && waiting) || (incoming.state == AgentReportState::released && !waiting)) {
      return false;
    }

    if (incoming.state == AgentReportState::exited) {
      const bool changed = report.has_value();
      clearReport();
      work.reset();
      return changed;
    }

    if (provider() == AgentProvider::codex && (incoming.state == AgentReportState::working || incoming.state == AgentReportState::waiting) && screen && screen->status == AgentStatus::ready) {
      screen.reset();
    }

    report_state = incoming.state;
    report_reason = incoming.blocked_reason;
    report_event.assign(incoming.event);
    report = AgentEvidence::report(provider() == AgentProvider::unknown ? incoming.provider : provider(), incoming.state, now);
    if (incoming.state == AgentReportState::working || incoming.state == AgentReportState::waiting) {
      work = report;
    }

    if (authority != AgentAuthority::resumed) {
      authority = AgentAuthority::active;
    }

    return true;
  }

  inline bool applyScreen(AgentSignal signal, ObservationTime now, AgentStatus projected, bool interrupted) noexcept {
    const auto process_provider = process ? process->provider : AgentProvider::unknown;
    if (process_provider != AgentProvider::unknown && signal.provider != AgentProvider::unknown && signal.provider != process_provider) {
      return false;
    }

    const auto known = process_provider != AgentProvider::unknown ? process_provider : signal.provider != AgentProvider::unknown ? signal.provider
                                                                                                                                 : provider();
    if (known == AgentProvider::unknown || (signal.status == AgentStatus::ready && !signal.identity_confirmed && provider() != signal.provider)) {
      return false;
    }

    if (signal.status == AgentStatus::ready && projected == AgentStatus::working && !signal.ready_confirmed) {
      return false;
    }

    if (known == AgentProvider::codex) {
      if (screen && now.before(screen->observed)) {
        return false;
      }

      if (report) {
        if (!report->observed.before(now)) {
          return false;
        }

        if (signal.status == AgentStatus::ready) {
          if (!signal.ready_confirmed || (report->status == AgentStatus::working && report_state != AgentReportState::settling && !report->expired(now.milliseconds))) {
            return false;
          }

          if (!interrupted) {
            report.reset();
          }
        } else if (report->status == AgentStatus::ready) {
          report.reset();
        }
      }
    }

    screen = AgentEvidence::screen(known, signal, now);
    if (signal.status == AgentStatus::blocked) {
      authority = AgentAuthority::obscured;
    }

    return true;
  }

  inline std::optional<AgentEvidence> choose(std::int64_t now) const noexcept {
    const auto shown = screen && !screen->expired(now) ? screen : std::nullopt;
    if (report && !report->expired(now)) {
      const auto since = work ? work->observed : report->observed;
      if (shown && shown->status == AgentStatus::blocked && provider() == AgentProvider::cursor && since.before(shown->observed)) {
        return shown;
      }

      return report;
    }

    if (shown) {
      return shown;
    }

    auto presence = process;
    if (presence && completionRequiresSignal(presence->provider)) {
      presence->status = AgentStatus::unknown;
    }

    return presence;
  }

  inline void expire(std::int64_t now) noexcept {
    if (screen && screen->expired(now)) {
      screen.reset();
    }

    if (report && report->expired(now)) {
      report.reset();
    }
  }

  inline void clearReport() noexcept {
    report.reset();
    report_state = AgentReportState::ready;
    report_reason = AgentBlockedReason::none;
    report_event.assign({});
  }

  std::optional<AgentEvidence> process;
  std::optional<AgentEvidence> screen;
  std::optional<AgentEvidence> report;
  std::optional<AgentEvidence> work;
  AgentProvider reporter = AgentProvider::unknown;
  AgentAuthority authority = AgentAuthority::candidate;
  AgentReportState report_state = AgentReportState::ready;
  AgentBlockedReason report_reason = AgentBlockedReason::none;
  FixedText<96> report_event;
  bool hooks_seen = false;
};

}
}

// Interface: agents/progress.cppm
export {
namespace telar::runtime {

class AgentProgress {
public:
  inline bool apply(const ReportAgentProgress &report) {
    if (!report.final_message.empty()) {
      final_message.assign(report.final_message);
    }

    switch (report.plan_op) {
    case AgentPlanOp::none:
      break;
    case AgentPlanOp::add:
      if (count_ == task_capacity) {
        return false;
      }
      tasks_[count_].subject.assign(report.plan_text);
      tasks_[count_++].status = AgentPlanStatus::pending;
      uses_tasks_ = true;
      break;
    case AgentPlanOp::mark:
      if (report.plan_index < count_) {
        tasks_[report.plan_index].status = report.plan_status;
      }
      break;
    case AgentPlanOp::set:
      count_ = 0;
      uses_tasks_ = false;
      done_ = report.plan_done;
      total_ = report.plan_total;
      step_.assign(report.plan_text);
      break;
    }

    return true;
  }

  inline std::uint16_t done() const noexcept {
    if (!uses_tasks_) {
      return done_;
    }
    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task &task) { return task.status == AgentPlanStatus::completed; }));
  }

  inline std::uint16_t total() const noexcept {
    if (!uses_tasks_) {
      return total_;
    }
    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task &task) { return task.status != AgentPlanStatus::deleted; }));
  }

  inline std::string_view step() const noexcept {
    if (!uses_tasks_) {
      return step_.view();
    }
    std::string_view pending;
    for (const auto &task : std::span{tasks_}.first(count_)) {
      if (task.status == AgentPlanStatus::in_progress) {
        return task.subject.view();
      }
      if (task.status == AgentPlanStatus::pending && pending.empty()) {
        pending = task.subject.view();
      }
    }

    return pending;
  }

  FixedText<2048> final_message;
  static constexpr std::size_t task_capacity = 128;

private:
  struct Task {
    FixedText<96> subject;
    AgentPlanStatus status = AgentPlanStatus::pending;
  };

  std::array<Task, task_capacity> tasks_{};
  std::size_t count_ = 0;
  bool uses_tasks_ = false;
  std::uint16_t done_ = 0;
  std::uint16_t total_ = 0;
  FixedText<96> step_;
};

}
}

// Interface: agents/session_file.cppm
export {
namespace telar::runtime {

struct SessionFileWatch {
  inline void configure(std::string_view reference, std::string_view file, AgentSessionFileKind format) {
    if (reference.empty() || file.empty() || (session.view() == reference && path.view() == file && kind == format)) {
      return;
    }

    session.assign(reference);
    path.assign(file);
    kind = format;
    resetProgress();
  }

  inline void clear() noexcept {
    session.assign({});
    path.assign({});
    resetProgress();
  }

  inline bool remember(std::string_view title) {
    if (last_title && last_title->view() == title) {
      return false;
    }

    last_title.emplace().assign(title);
    return true;
  }

  FixedText<64> session;
  FixedText<1024> path;
  AgentSessionFileKind kind = AgentSessionFileKind::claude_transcript;
  std::optional<std::uint64_t> offset;
  std::optional<FixedText<96>> last_title;
  std::chrono::steady_clock::time_point checked_at{};
  std::uint64_t revision = 0;

private:
  inline void resetProgress() noexcept {
    ++revision;
    offset.reset();
    last_title.reset();
    checked_at = {};
  }
};

struct SessionFileRequest {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  SessionFileWatch watch;
};

struct SessionFileResult {
  SessionFileRequest request;
  std::optional<std::uint64_t> offset;
  std::optional<FixedText<96>> title;
};

}
}

// Interface: agents/agent.cppm
export {
namespace telar::runtime {

struct Agent {
  inline Agent(std::uint64_t pane, std::uint64_t generation)
      : pane(pane),
        generation(generation) {}

  inline void setSession(std::string_view value) {
    if (!value.empty()) {
      session.assign(value);
    }
  }

  inline bool report(const ReportAgent &incoming, ObservationTime now = ObservationTime::now()) {
    if (!evidence.accepts(incoming.provider)) {
      return false;
    }

    evidence.claim(incoming.provider);
    if (incoming.state != AgentReportState::continuing) {
      setSession(incoming.session);
      if (!incoming.session_file.empty()) {
        file_watch.configure(session.view(), incoming.session_file, incoming.session_file_kind);
      }
    }

    if (!evidence.applyReport(incoming, now)) {
      return false;
    }

    if (incoming.state != AgentReportState::continuing && incoming.state != AgentReportState::exited) {
      interrupt_at.reset();
      interrupt_idle_at.reset();
      interrupt_draft_cleared = false;
    }

    return project(now.milliseconds);
  }

  inline bool observeProcess(ProcessIdentity identity, AgentProvider incoming, ObservationTime now = ObservationTime::now()) {
    if (process_identity == identity && evidence.process && evidence.process->provider == incoming) {
      return false;
    }

    const bool replacing = evidence.process.has_value();
    if ((!replacing && evidence.reporter != AgentProvider::unknown && evidence.reporter != incoming) || (replacing && evidence.process->provider != incoming)) {
      forgetReports();
    }

    if (replacing) {
      evidence.screen.reset();
      evidence.report.reset();
      evidence.work.reset();
      evidence.hooks_seen = false;
      unreported_work_at.reset();
    }

    evidence.reporter = AgentProvider::unknown;
    evidence.process = AgentEvidence::process(incoming, now);
    process_identity = identity;
    if (replacing || evidence.authority == AgentAuthority::candidate || evidence.authority == AgentAuthority::stale || evidence.authority == AgentAuthority::exited) {
      evidence.authority = AgentAuthority::active;
    }

    return project(now.milliseconds);
  }

  inline bool observeScreen(AgentSignal signal, ObservationTime now = ObservationTime::now()) {
    if (!evidence.applyScreen(signal, now, status, interrupt_at.has_value())) {
      return false;
    }

    if (!evidence.report) {
      interrupt_at.reset();
      interrupt_idle_at.reset();
    }

    if (signal.status != AgentStatus::working) {
      unreported_work_at.reset();
    } else if (!evidence.hooks_seen && !unreported_work_at) {
      unreported_work_at = now.milliseconds;
    }

    return project(now.milliseconds);
  }

  inline bool setProcessContext(SessionHost host, bool installed, std::optional<ProcessIdentity> identity) noexcept {
    const bool changed = session_host != host || hooks_installed != installed;
    session_host = host;
    in_pane = host == SessionHost::pane;
    hooks_installed = installed;
    agent_identity = identity;
    return changed;
  }

  inline std::string_view eventFor(const AgentEvidence &selected, std::int64_t now) const noexcept {
    if (selected.source == AgentSource::lifecycle_report) {
      return evidence.report_event.view();
    }

    constexpr std::int64_t missing_hooks_grace_ms = 5'000;
    if (session_host == SessionHost::shared_server && hooks_installed && !evidence.hooks_seen && unreported_work_at && now - *unreported_work_at >= missing_hooks_grace_ms) {
      return "no hooks from this pane: if it runs on a shared server, start it with --no-daemon";
    }

    return {};
  }

  inline bool project(std::int64_t now) {
    const auto selected = evidence.choose(now);
    if (!selected) {
      return false;
    }

    auto next_status = selected->status;
    if (next_status != AgentStatus::ready) {
      acknowledged = true;
    } else {
      if (status == AgentStatus::working) {
        acknowledged = false;
      }

      next_status = acknowledged ? AgentStatus::ready : AgentStatus::done;
    }

    const auto next_provider = evidence.process ? evidence.process->provider : selected->provider != AgentProvider::unknown ? selected->provider
                                                                           : evidence.screen                                ? evidence.screen->provider
                                                                                                                            : AgentProvider::unknown;
    const auto next_reason = next_status == AgentStatus::blocked ? (selected->source == AgentSource::lifecycle_report && evidence.report_reason != AgentBlockedReason::none ? evidence.report_reason : AgentBlockedReason::other) : AgentBlockedReason::none;
    const auto next_event = eventFor(*selected, now);
    const bool changed = provider != next_provider || status != next_status || source != selected->source || authority != evidence.authority || confidence != selected->confidence || observed_at != selected->observed.milliseconds || expires_at != selected->expires_at || blocked_reason != next_reason || event.view() != next_event || projected_process != process_identity;
    if (status != next_status || changed_at == 0) {
      changed_at = now;
    }

    provider = next_provider;
    status = next_status;
    source = selected->source;
    authority = evidence.authority;
    confidence = selected->confidence;
    observed_at = selected->observed.milliseconds;
    expires_at = selected->expires_at;
    blocked_reason = next_reason;
    event.assign(next_event);
    projected_process = process_identity;
    return changed;
  }

  inline void forgetReports() {
    evidence.clearReport();
    evidence.work.reset();
    evidence.hooks_seen = false;
    unreported_work_at.reset();
    session.assign({});
    file_watch.clear();
    worktree = 0;
    progress = {};
    if (title_source == AgentTitleSource::agent) {
      title.assign({});
      title_source = AgentTitleSource::telar;
      title_state = AgentTitleState::placeholder;
      description_capture.clear();
      description_phase = DescriptionPhase::waiting_query;
    }
  }

  inline bool reportTitle(std::string_view value) {
    if (value.empty()) {
      if (title_source != AgentTitleSource::agent) {
        return false;
      }

      title.assign({});
      title_source = AgentTitleSource::telar;
      title_state = AgentTitleState::placeholder;
      finishTitleCapture();
      return true;
    }

    validateUtf8(value);
    if (value.size() > 96 || std::ranges::any_of(value, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      throw EncodingError{"Invalid agent session title"};
    }
    if (title_source == AgentTitleSource::agent && title.view() == value) {
      return false;
    }

    title.assign(value);
    title_source = AgentTitleSource::agent;
    title_state = AgentTitleState::ready;
    finishTitleCapture();
    return true;
  }

  inline void observeInput(std::span<const Byte> bytes) {
    if (description_phase == DescriptionPhase::waiting_query && description_capture.feed(bytes)) {
      description_phase = DescriptionPhase::waiting_work;
    }
  }

  inline bool queueDescription() noexcept {
    if (description_phase != DescriptionPhase::waiting_work || status != AgentStatus::working) {
      return false;
    }

    description_phase = DescriptionPhase::queued;
    title_state = AgentTitleState::pending;
    return true;
  }

  inline void finishTitleCapture() noexcept {
    description_phase = DescriptionPhase::finished;
    description_capture.clear();
  }

  inline bool hasPendingDescription() const noexcept {
    return description_phase == DescriptionPhase::queued || description_phase == DescriptionPhase::running;
  }

  std::uint64_t pane;
  std::uint64_t generation;
  AgentEvidenceState evidence;
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  AgentBlockedReason blocked_reason = AgentBlockedReason::none;
  AgentSource source = AgentSource::screen;
  AgentAuthority authority = AgentAuthority::candidate;
  Byte confidence = 0;
  AgentTitleSource title_source = AgentTitleSource::telar;
  AgentTitleState title_state = AgentTitleState::placeholder;
  std::array<Byte, 16> session_id{};
  FixedText<64> session;
  SessionFileWatch file_watch;
  FixedText<96> event;
  FixedText<96> title;
  DescriptionCapture description_capture;
  DescriptionPhase description_phase = DescriptionPhase::waiting_query;
  std::uint64_t description_revision = 0;
  AgentProgress progress;
  std::uint64_t worktree = 0;
  std::uint64_t sequence = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t title_revision = 0;
  std::int64_t observed_at = 0;
  std::int64_t changed_at = 0;
  std::int64_t expires_at = 0;
  bool acknowledged = true;
  bool in_pane = false;
  std::optional<ProcessIdentity> process_identity;
  std::optional<ProcessIdentity> projected_process;
  std::optional<ProcessIdentity> agent_identity;
  SessionHost session_host = SessionHost::unknown;
  bool hooks_installed = false;
  std::optional<std::int64_t> unreported_work_at;
  std::uint64_t interrupt_revision = 0;
  bool interrupt_draft_cleared = false;
  std::optional<std::chrono::steady_clock::time_point> interrupt_at;
  std::optional<std::chrono::steady_clock::time_point> interrupt_idle_at;
};

}
}

// Interface: agents/registry.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class AgentRegistry {
public:
  inline explicit AgentRegistry(Memory &memory)
      : memory_(memory),
        records_(AllocatorRef<Owned<Agent, Memory>, Memory>{memory}) {
    records_.reserve(capacity);
  }

  inline Agent *find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    for (const auto &agent : records_) {
      if (agent->pane == pane && agent->generation == generation) {
        return agent.get();
      }
    }

    return nullptr;
  }

  inline Agent &ensure(std::uint64_t pane, std::uint64_t generation) {
    if (auto *existing = find(pane, generation)) {
      return *existing;
    }
    if (records_.size() == capacity) {
      throw RequestError{FailureCode::resource_limit, "Agent capacity reached"};
    }

    records_.push_back(makeOwned<Agent>(memory_, pane, generation));
    return *records_.back();
  }

  template <typename Predicate>
  inline void removeIf(Predicate &&predicate) {
    if (std::erase_if(records_, [&](const auto &agent) { return predicate(*agent); }) != 0) {
      changed();
    }
  }

  inline auto records() const noexcept {
    return std::span{records_};
  }

  inline void changed() noexcept {
    ++revision_;
  }

  inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  static constexpr std::size_t capacity = 64;

private:
  Memory &memory_;
  Vector<Owned<Agent, Memory>, Memory> records_;
  std::uint64_t revision_ = 1;
};

}
}

// Interface: agents/session_file_reader.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class SessionFileReader {
public:
  using Request = SessionFileRequest;
  using Result = SessionFileResult;

  inline explicit SessionFileReader(Memory &memory)
      : path_(AllocatorRef<char, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}),
        decoded_(AllocatorRef<char, Memory>{memory}) {}

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("agents.readSessionTitle");
    Result result{.request = request, .offset = request.watch.offset, .title = std::nullopt};
    try {
      path_ = request.watch.path.view();
      switch (request.watch.kind) {
      case AgentSessionFileKind::claude_transcript:
        claude(request.watch, result);
        break;
      case AgentSessionFileKind::codex_state:
        codex(request.watch, result);
        break;
      case AgentSessionFileKind::cursor_meta:
        cursor(request.watch, result);
        break;
      }
    } catch (const std::exception &) {
    }

    return result;
  }

  inline void stop() noexcept {}

private:
  inline void codex(const SessionFileWatch &watch, Result &result) {
    Database database{path_.c_str(), DatabaseAccess::read_only};
    Statement statement{database, "SELECT name FROM threads WHERE id = ?1"};
    statement.bind(1, watch.session.view());
    if (statement.next()) {
      result.title.emplace().assign(utf8Prefix(statement.text(0), title_capacity));
    }
  }

  inline static bool cursorPath(std::string_view path, std::string_view session) noexcept {
    if (session.empty() || session.size() > 64 || !std::ranges::all_of(session, [](char byte) { return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-'; })) {
      return false;
    }
    if (!path.ends_with("/meta.json")) {
      return false;
    }

    path.remove_suffix(sizeof("/meta.json") - 1);
    return path.substr(path.rfind('/') + 1) == session;
  }

  inline void cursor(const SessionFileWatch &watch, Result &result) {
    if (!cursorPath(path_, watch.session.view())) {
      return;
    }

    FileDescriptor file{::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    const auto size = regularFileSize(file);
    if (!size || *size >= metadata_capacity) {
      return;
    }

    const auto input = read(file.get(), 0, metadata_capacity);
    if (input.size() == metadata_capacity) {
      return;
    }

    result.title = readTitle(input, std::nullopt);
  }

  inline void claude(const SessionFileWatch &watch, Result &result) {
    FileDescriptor file{::open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
    if (!file) {
      if (!watch.offset) {
        result.offset = 0;
      }
      return;
    }

    const auto size = regularFileSize(file);
    if (!size) {
      return;
    }
    if (!watch.offset) {
      result.offset = *size;
      return;
    }

    const auto from = *size < *watch.offset ? 0 : *watch.offset;
    const auto input = read(file.get(), from, transcript_capacity);
    std::size_t consumed = 0;
    while (consumed < input.size()) {
      const auto newline = input.find('\n', consumed);
      if (newline == std::string_view::npos) {
        break;
      }

      const auto line = input.substr(consumed, newline - consumed);
      consumed = newline + 1;
      if (line.size() > line_capacity || !line.starts_with("{\"type\":\"custom-title\"")) {
        continue;
      }

      try {
        if (const auto title = readTitle(line, watch.session.view())) {
          result.title = title;
        }
      } catch (const std::exception &) {
      }
    }

    result.offset = from + (consumed == 0 && input.size() == transcript_capacity ? input.size() : consumed);
  }

  inline std::optional<FixedText<96>> readTitle(std::string_view input, std::optional<std::string_view> session) {
    validateUtf8(input);
    const auto object = JsonValue::parse(input);
    FixedText<96> title;
    bool has_title = false;
    bool has_session = false;
    bool matches_session = !session;
    object.eachMember([&](const JsonValue &key, const JsonValue &value) {
      key.string(decoded_);
      if (decoded_ == (session ? "customTitle" : "title")) {
        if (has_title) {
          throw EncodingError{"Duplicate session title"};
        }

        has_title = true;
        value.string(decoded_);
        title.assign(utf8Prefix(decoded_, title_capacity));
      } else if (session && decoded_ == "sessionId") {
        if (has_session) {
          throw EncodingError{"Duplicate session reference"};
        }

        has_session = true;
        value.string(decoded_);
        matches_session = decoded_ == *session;
      }
    });

    return matches_session ? std::optional{title} : std::nullopt;
  }

  inline static std::optional<std::uint64_t> regularFileSize(const FileDescriptor &file) noexcept {
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0) {
      return std::nullopt;
    }

    return static_cast<std::uint64_t>(metadata.st_size);
  }

  inline std::string_view read(int descriptor, std::uint64_t offset, std::size_t limit) {
    bytes_.resize(limit);
    std::size_t filled = 0;
    while (filled < limit) {
      if (offset > static_cast<std::uint64_t>(INT64_MAX) - filled) {
        throw EncodingError{"Agent session file offset is outside its bounds"};
      }

      const auto count = ::pread(descriptor, bytes_.data() + filled, limit - filled, static_cast<off_t>(offset + filled));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0) {
        throw SystemError{"Read agent session file"};
      }
      if (count == 0) {
        break;
      }

      filled += static_cast<std::size_t>(count);
    }

    return {bytes_.data(), filled};
  }

  static constexpr std::size_t title_capacity = 96;
  static constexpr std::size_t metadata_capacity = 16 * 1024;
  static constexpr std::size_t transcript_capacity = 64 * 1024;
  static constexpr std::size_t line_capacity = 4096;
  String<Memory> path_;
  Vector<char, Memory> bytes_;
  String<Memory> decoded_;
};

}
}

// Interface: agents/snapshot.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class AgentSnapshotBuilder {
public:
  inline void publish(ClientSession<Memory> &client, const RuntimeModel<Memory> &model, const AgentRegistry<Memory> &registry) {
    // The entries view the model, the registry and these texts only while the snapshot is sent.
    std::array<AgentSnapshotEntry, AgentRegistry<Memory>::capacity> entries;
    auto &directories = directories_;
    auto &placeholders = placeholders_;
    std::size_t count = 0;
    const auto now = wallMilliseconds();
    for (const auto &agent : registry.records()) {
      const auto *pane = model.panes.find(agent->pane);
      if (pane == nullptr || pane->generation != agent->generation || agent->sequence == 0) {
        continue;
      }
      const auto *workspace = model.workspaces.find(pane->location.workspace.id);
      const auto *tab = workspace == nullptr ? nullptr : workspace->tab(pane->location.tab_id);
      if (tab == nullptr) {
        continue;
      }
      const auto position = std::find(tab->panes.begin(), tab->panes.end(), pane->id);
      if (position == tab->panes.end()) {
        continue;
      }

      auto provider = describeProvider(agent->provider);
      const auto *manifest = model.manifests.find(agent->provider);
      if (manifest != nullptr) {
        provider = {manifest->name.view(), manifest->displayName(), manifest->placeholderTitle(placeholders[count]), manifest->attachments};
      }
      std::string_view cwd = pane->cwd;
      const char *home = std::getenv("HOME");
      if (home != nullptr && cwd.starts_with(home) && (cwd.size() == std::strlen(home) || cwd[std::strlen(home)] == '/')) {
        std::array<char, 48> shortened{'~'};
        const auto suffix = utf8Prefix(cwd.substr(std::strlen(home)), 47);
        std::copy(suffix.begin(), suffix.end(), shortened.begin() + 1);
        directories[count].assign({shortened.data(), suffix.size() + 1});
      } else {
        directories[count].assign(utf8Prefix(cwd, 48));
      }

      entries[count] = {
          .pane_id = pane->id,
          .pane_generation = pane->generation,
          .location = pane->location,
          .pane_index = static_cast<std::uint16_t>(position - tab->panes.begin() + 1),
          .process_id = static_cast<std::uint32_t>(agent->process_identity ? agent->process_identity->pid : pane->process->processId()),
          .session_id = agent->session_id,
          .workspace_label = utf8Prefix(workspace->displayName(), 48),
          .tab_label = tab->label,
          .session_title = agent->title_source == AgentTitleSource::telar && !pane->terminal.effects.title().empty() ? utf8Prefix(pane->terminal.effects.title(), 96) : agent->title.view().empty() ? provider.placeholder
                                                                                                                                                                                                    : agent->title.view(),
          .title_source = agent->title_source == AgentTitleSource::telar && !pane->terminal.effects.title().empty() ? AgentTitleSource::terminal : agent->title_source,
          .title_state = agent->title_state,
          .cwd_label = directories[count].view(),
          .provider = agent->provider,
          .provider_name = provider.name,
          .display_name = provider.display_name,
          .icon = manifest != nullptr ? manifest->icon.view() : std::string_view{},
          .attachments = provider.attachments,
          .status = agent->status,
          .blocked_reason = agent->blocked_reason,
          .last_event = agent->event.view(),
          .status_age_s = static_cast<std::uint32_t>(std::clamp<std::int64_t>((now - agent->changed_at) / 1000, 0, UINT32_MAX)),
          .source = agent->source,
          .authority = agent->authority,
          .confidence = agent->confidence,
          .sequence = agent->sequence,
          .observed_at_ms = agent->observed_at,
          .expires_at_ms = agent->expires_at,
          .work_tree = agent->worktree,
          .final_message = agent->progress.final_message.view(),
          .plan_done = agent->progress.done(),
          .plan_total = agent->progress.total(),
          .plan_step = agent->progress.step(),
      };
      ++count;
    }

    client.connection.send(AgentSnapshot{registry.revision() + model.workspace_revision, std::span{entries}.first(count)});
    client.agent_revision = registry.revision();
    client.agent_workspace_revision = model.workspace_revision;
  }

private:
  std::array<FixedText<48>, AgentRegistry<Memory>::capacity> directories_;
  std::array<FixedText<96>, AgentRegistry<Memory>::capacity> placeholders_;
};

}
}
