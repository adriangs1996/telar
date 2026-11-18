module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.agents.snapshot;

import std;
import telar.sys.posix;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.runtime.history.store;
import telar.platform.error;
import telar.base.ds;

namespace telar::runtime {

  AgentProvider AgentEvidenceState::provider() const noexcept {
    return process ? process->provider : screen ? screen->provider
                                                : AgentProvider::unknown;
  }

  bool AgentEvidenceState::accepts(AgentProvider incoming) const noexcept {
    const auto running = process ? process->provider : reporter;

    return incoming == AgentProvider::unknown || running == AgentProvider::unknown || running == incoming;
  }

  void AgentEvidenceState::claim(AgentProvider incoming) noexcept {
    if (!process && incoming != AgentProvider::unknown) {
      reporter = incoming;
    }
  }

  bool AgentEvidenceState::applyReport(const ReportAgent& incoming, ObservationTime now) {
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

      report.getMut().expires_at = now.milliseconds + AgentEvidence::report_working_expiry.count();
      return true;
    }

    const bool waiting = report && report_state == AgentReportState::waiting && !report->expired(now.milliseconds);
    if ((incoming.state == AgentReportState::idle && waiting) || (incoming.state == AgentReportState::released && !waiting)) {
      return false;
    }

    if (incoming.state == AgentReportState::exited) {
      const bool changed = report.hasValue();

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

  bool AgentEvidenceState::applyScreen(AgentSignal signal, ObservationTime now, AgentStatus projected, bool interrupted) noexcept {
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

  ds::Option<AgentEvidence> AgentEvidenceState::choose(std::int64_t now) const noexcept {
    const auto shown = screen && !screen->expired(now) ? screen : ds::none;

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
      presence.getMut().status = AgentStatus::unknown;
    }

    return presence;
  }

  void AgentEvidenceState::expire(std::int64_t now) noexcept {
    if (screen && screen->expired(now)) {
      screen.reset();
    }

    if (report && report->expired(now)) {
      report.reset();
    }
  }

  void AgentEvidenceState::clearReport() noexcept {
    report.reset();
    report_state = AgentReportState::ready;
    report_reason = AgentBlockedReason::none;
    report_event.assign({});
  }

  bool AgentProgress::apply(const ReportAgentProgress& report) {
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

  std::uint16_t AgentProgress::done() const noexcept {
    if (!uses_tasks_) {
      return done_;
    }

    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task& task) {
      return task.status == AgentPlanStatus::completed;
    }));
  }

  std::uint16_t AgentProgress::total() const noexcept {
    if (!uses_tasks_) {
      return total_;
    }

    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task& task) {
      return task.status != AgentPlanStatus::deleted;
    }));
  }

  std::string_view AgentProgress::step() const noexcept {
    if (!uses_tasks_) {
      return step_.view();
    }

    std::string_view pending;

    for (const auto& task : std::span{tasks_}.first(count_)) {
      if (task.status == AgentPlanStatus::in_progress) {
        return task.subject.view();
      }

      if (task.status == AgentPlanStatus::pending && pending.empty()) {
        pending = task.subject.view();
      }
    }

    return pending;
  }

  void SessionFileWatch::configure(std::string_view reference, std::string_view file, AgentSessionFileKind format) {
    if (reference.empty() || file.empty() || (session.view() == reference && path.view() == file && kind == format)) {
      return;
    }

    session.assign(reference);
    path.assign(file);
    kind = format;
    resetProgress();
  }

  void SessionFileWatch::clear() noexcept {
    session.assign({});
    path.assign({});
    resetProgress();
  }

  bool SessionFileWatch::remember(std::string_view title) {
    if (last_title && last_title->view() == title) {
      return false;
    }

    last_title.emplace().assign(title);
    return true;
  }

  void SessionFileWatch::resetProgress() noexcept {
    ++revision;
    offset.reset();
    last_title.reset();
    checked_at = {};
  }

  Agent::Agent(std::uint64_t pane, std::uint64_t generation)
      : pane(pane),
        generation(generation) {}

  void Agent::setSession(std::string_view value) {
    if (!value.empty()) {
      session.assign(value);
    }
  }

  bool Agent::report(const ReportAgent& incoming, ObservationTime now) {
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

  bool Agent::observeProcess(ProcessIdentity identity, AgentProvider incoming, ObservationTime now) {
    if (process_identity == identity && evidence.process && evidence.process->provider == incoming) {
      return false;
    }

    const bool replacing = evidence.process.hasValue();
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

  bool Agent::observeScreen(AgentSignal signal, ObservationTime now) {
    if (!evidence.applyScreen(signal, now, status, interrupt_at.hasValue())) {
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

  bool Agent::setProcessContext(SessionHost host, bool installed, ds::Option<ProcessIdentity> identity) noexcept {
    const bool changed = session_host != host || hooks_installed != installed;

    session_host = host;
    in_pane = host == SessionHost::pane;
    hooks_installed = installed;
    agent_identity = identity;
    return changed;
  }

  std::string_view Agent::eventFor(const AgentEvidence& selected, std::int64_t now) const noexcept {
    if (selected.source == AgentSource::lifecycle_report) {
      return evidence.report_event.view();
    }

    constexpr std::int64_t missing_hooks_grace_ms = 5'000;
    if (session_host == SessionHost::shared_server && hooks_installed && !evidence.hooks_seen && unreported_work_at && now - *unreported_work_at >= missing_hooks_grace_ms) {
      return "no hooks from this pane: if it runs on a shared server, start it with --no-daemon";
    }

    return {};
  }

  bool Agent::project(std::int64_t now) {
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

  void Agent::forgetReports() {
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

  bool Agent::reportTitle(std::string_view value) {
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
    if (value.size() > 96 || std::ranges::any_of(value, [](unsigned char byte) {
          return byte < 0x20 || byte == 0x7f;
        })) {
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

  void Agent::observeInput(std::span<const Byte> bytes) {
    if (description_phase == DescriptionPhase::waiting_query && description_capture.feed(bytes)) {
      description_phase = DescriptionPhase::waiting_work;
    }
  }

  bool Agent::queueDescription() noexcept {
    if (description_phase != DescriptionPhase::waiting_work || status != AgentStatus::working) {
      return false;
    }

    description_phase = DescriptionPhase::queued;
    title_state = AgentTitleState::pending;
    return true;
  }

  void Agent::finishTitleCapture() noexcept {
    description_phase = DescriptionPhase::finished;
    description_capture.clear();
  }

  bool Agent::hasPendingDescription() const noexcept {
    return description_phase == DescriptionPhase::queued || description_phase == DescriptionPhase::running;
  }

  template <Allocator Memory>
  AgentRegistry<Memory>::AgentRegistry(Memory& memory)
      : memory_(memory),
        records_(AllocatorRef<Owned<Agent, Memory>, Memory>{memory}) {
    records_.reserve(capacity);
  }

  template <Allocator Memory>
  Agent* AgentRegistry<Memory>::find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    for (const auto& agent : records_) {
      if (agent->pane == pane && agent->generation == generation) {
        return agent.get();
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  Agent& AgentRegistry<Memory>::ensure(std::uint64_t pane, std::uint64_t generation) {
    if (auto* existing = find(pane, generation)) {
      return *existing;
    }

    if (records_.size() == capacity) {
      throw RequestError{FailureCode::resource_limit, "Agent capacity reached"};
    }

    records_.push_back(makeOwned<Agent>(memory_, pane, generation));
    return *records_.back();
  }

  template <Allocator Memory>
  std::span<const Owned<Agent, Memory>> AgentRegistry<Memory>::records() const noexcept {
    return std::span{records_};
  }

  template <Allocator Memory>
  void AgentRegistry<Memory>::changed() noexcept {
    ++revision_;
  }

  template <Allocator Memory>
  std::uint64_t AgentRegistry<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  SessionFileReader<Memory>::SessionFileReader(Memory& memory)
      : path_(AllocatorRef<char, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}),
        decoded_(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  auto SessionFileReader<Memory>::observe(const Request& request) noexcept -> Result {
    TELAR_TRACE("agents.readSessionTitle");
    Result result{.request = request, .offset = request.watch.offset, .title = ds::none};

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
    } catch (const std::exception&) {
    }

    return result;
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::stop() noexcept {}

  template <Allocator Memory>
  void SessionFileReader<Memory>::codex(const SessionFileWatch& watch, Result& result) {
    Database database{path_.c_str(), DatabaseAccess::read_only};
    Statement statement{database, "SELECT name FROM threads WHERE id = ?1"};

    statement.bind(1, watch.session.view());
    if (statement.next()) {
      result.title.emplace().assign(utf8Prefix(statement.text(0), title_capacity));
    }
  }

  template <Allocator Memory>
  bool SessionFileReader<Memory>::cursorPath(std::string_view path, std::string_view session) noexcept {
    if (session.empty() || session.size() > 64 || !std::ranges::all_of(session, [](char byte) {
          return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-';
        })) {
      return false;
    }

    if (!path.ends_with("/meta.json")) {
      return false;
    }

    path.remove_suffix(sizeof("/meta.json") - 1);
    return path.substr(path.rfind('/') + 1) == session;
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::cursor(const SessionFileWatch& watch, Result& result) {
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

    result.title = readTitle(input, ds::none);
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::claude(const SessionFileWatch& watch, Result& result) {
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
      } catch (const std::exception&) {
      }
    }

    result.offset = from + (consumed == 0 && input.size() == transcript_capacity ? input.size() : consumed);
  }

  template <Allocator Memory>
  ds::Option<FixedText<96>> SessionFileReader<Memory>::readTitle(std::string_view input, ds::Option<std::string_view> session) {
    validateUtf8(input);
    const auto object = JsonValue::parse(input);
    FixedText<96> title;
    bool has_title = false;
    bool has_session = false;
    bool matches_session = !session;

    object.eachMember([&](const JsonValue& key, const JsonValue& value) {
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

    return matches_session ? ds::Option{title} : ds::none;
  }

  template <Allocator Memory>
  ds::Option<std::uint64_t> SessionFileReader<Memory>::regularFileSize(const FileDescriptor& file) noexcept {
    struct stat metadata{};
    if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0) {
      return ds::none;
    }

    return static_cast<std::uint64_t>(metadata.st_size);
  }

  template <Allocator Memory>
  std::string_view SessionFileReader<Memory>::read(int descriptor, std::uint64_t offset, std::size_t limit) {
    bytes_.resize(limit);
    std::size_t filled = 0;

    while (filled < limit) {
      if (offset > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) - filled) {
        throw EncodingError{"Agent session file offset is outside its bounds"};
      }

      const auto count = ::pread(descriptor, bytes_.data() + filled, limit - filled, static_cast<off_t>(offset + filled));
      if (count < 0 && sys::lastError() == EINTR) {
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

  template class AgentRegistry<Memory>;
  template class AgentRegistry<ConcurrentMemory>;
  template class AgentRegistry<SystemAllocator>;
  template class SessionFileReader<Memory>;
  template class SessionFileReader<ConcurrentMemory>;

}
