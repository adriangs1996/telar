module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.agents.snapshot;

import std;
import telar.sys.posix;
import telar.base.text;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.runtime.history.store;
import telar.platform.error;
import telar.runtime.agents.screen_inference;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    AgentProvider projectedProvider(const AgentEvidenceState& evidence, const AgentEvidence& selected) noexcept {
      if (evidence.process) {
        return evidence.process->provider;
      }

      if (selected.provider != AgentProvider::unknown) {
        return selected.provider;
      }

      return evidence.screen ? evidence.screen->provider : AgentProvider::unknown;
    }

    AgentBlockedReason projectedReason(AgentStatus status, const AgentEvidenceState& evidence, const AgentEvidence& selected) noexcept {
      if (status != AgentStatus::blocked) {
        return AgentBlockedReason::none;
      }

      return selected.source == AgentSource::lifecycle_report && evidence.report_reason != AgentBlockedReason::none ? evidence.report_reason : AgentBlockedReason::other;
    }

  }

  AgentProvider AgentEvidenceState::provider() const noexcept {
    if (process) {
      return process->provider;
    }

    return screen ? screen->provider : AgentProvider::unknown;
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

    settled = report->status == AgentStatus::ready || report->status == AgentStatus::failed ? report->status : AgentStatus::unknown;

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

    // From here on the screen shows something else than the evidence it gave before: a screen
    // this signal does not replace no longer backs that evidence.
    const bool was_current = screen_current;
    const auto lose = [&] {
      screen_current = false;
      if (was_current) {
        screen_lost_at = now.milliseconds;
      }

      return was_current;
    };

    if (signal.status == AgentStatus::unknown) {
      return lose();
    }

    auto known = provider();

    if (process_provider != AgentProvider::unknown) {
      known = process_provider;
    } else if (signal.provider != AgentProvider::unknown) {
      known = signal.provider;
    }

    if (known == AgentProvider::unknown || (signal.status == AgentStatus::ready && !signal.identity_confirmed && provider() != signal.provider)) {
      return lose();
    }

    if (signal.status == AgentStatus::ready && projected == AgentStatus::working && !signal.ready_confirmed) {
      return lose();
    }

    if (known == AgentProvider::codex && !applyCodexScreen(signal, now, interrupted)) {
      return lose();
    }

    screen = AgentEvidence::screen(known, signal, now);
    screen_current = true;
    if (signal.status == AgentStatus::blocked) {
      authority = AgentAuthority::obscured;
    } else if (authority == AgentAuthority::obscured) {
      authority = AgentAuthority::active;
    }

    if (signal.status == AgentStatus::ready) {
      settled = AgentStatus::ready;
    } else if (signal.status == AgentStatus::working || signal.status == AgentStatus::blocked) {
      settled = AgentStatus::unknown;
    }

    return true;
  }

  bool AgentEvidenceState::applyCodexScreen(AgentSignal signal, ObservationTime now, bool interrupted) noexcept {
    if (screen && now.before(screen->observed)) {
      return false;
    }

    if (!report) {
      return true;
    }

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

    return true;
  }

  ds::Option<AgentEvidence> AgentEvidenceState::choose(std::int64_t now) const noexcept {
    const bool shown = screen && !screen->expired(now);

    if (const auto reported = activeReport(now)) {
      return shown && screen_current && supersedes(*reported, now) ? screen : reported;
    }

    // Working phrases an agent's screen no longer shows end its work after a while; a screen
    // reader's working evidence holds until the screen shows the agent's next state.
    if (shown && (screen_current || screen->status != AgentStatus::working || hasIdleScreen(provider()) || now - screen_lost_at < lost_working.count())) {
      return screen;
    }

    auto presence = process;
    if (presence && settled != AgentStatus::unknown) {
      presence.getMut().status = settled;
    } else if (presence && completionRequiresSignal(presence->provider)) {
      presence.getMut().status = AgentStatus::unknown;
    }

    return presence;
  }

  ds::Option<AgentEvidence> AgentEvidenceState::activeReport(std::int64_t now) const noexcept {
    if (!report) {
      return ds::none;
    }

    if (!report->expired(now)) {
      return report;
    }

    if (report_state != AgentReportState::settling) {
      return ds::none;
    }

    auto ended = *report;

    ended.status = AgentStatus::ready;
    ended.expires_at = report->expires_at + AgentEvidence::settled_expiry.count();
    return ended;
  }

  bool AgentEvidenceState::supersedes(const AgentEvidence& reported, std::int64_t now) const noexcept {
    const auto known = provider();
    if (!screen || !hasIdleScreen(known)) {
      return false;
    }

    switch (screen->status) {
    case AgentStatus::blocked:
      // Cursor's question, read from its phrases, holds until its next work: its loop stops while
      // it waits on the user, so its stop leaves the question on screen.
      if (known == AgentProvider::cursor) {
        return reported.status != AgentStatus::blocked && (work ? work->observed : reported.observed).before(screen->observed);
      }

      // Claude's and Codex's dialogs, read from their footers, hold while they show, though a tool
      // that runs beside the one they ask about reports work.
      return reported.status == AgentStatus::working;
    case AgentStatus::working:
      return reported.status == AgentStatus::blocked;
    case AgentStatus::ready:
      // Claude and Antigravity end a turn the user interrupts, or a permission the user denies,
      // with no hook. A turn waiting on background work shows the idle prompt until that work wakes it.
      return (known == AgentProvider::claude || known == AgentProvider::antigravity) && report_state != AgentReportState::waiting && (reported.status == AgentStatus::working || reported.status == AgentStatus::blocked) && reported.observed.before(screen->observed) && now - screen->observed.milliseconds >= ready_settle.count();
    case AgentStatus::unknown:
    case AgentStatus::failed:
    case AgentStatus::done:
      return false;
    }

    return false;
  }

  void AgentEvidenceState::expire(std::int64_t now) noexcept {
    // A screen the observer still reads as it was keeps its evidence: nothing on it changed.
    if (screen && screen->expired(now)) {
      if (screen_current) {
        screen.getMut().expires_at = now + (screen->status == AgentStatus::working ? AgentEvidence::screen_working_expiry : AgentEvidence::settled_expiry).count();
      } else {
        screen.reset();
      }
    }

    if (report && report->expired(now)) {
      if (const auto ended = activeReport(now)) {
        report = ended;
        report_state = AgentReportState::ready;
        settled = AgentStatus::ready;
      } else {
        report.reset();
      }
    }
  }

  void AgentEvidenceState::clearReport() noexcept {
    report.reset();
    report_state = AgentReportState::ready;
    report_reason = AgentBlockedReason::none;
    report_event = {};
  }

  bool AgentProgress::apply(const ReportAgentProgress& report) {
    if (!report.final_message.empty()) {
      final_message_.assign(report.final_message);
    }

    switch (report.plan_op) {
    case AgentPlanOp::none:
      break;
    case AgentPlanOp::add:
      if (count_ == task_capacity) {
        return false;
      }

      tasks_.atMut(count_).subject.assign(report.plan_text);
      tasks_.atMut(count_++).status = AgentPlanStatus::pending;
      uses_tasks_ = true;
      break;
    case AgentPlanOp::mark:
      if (report.plan_index < count_) {
        tasks_.atMut(report.plan_index).status = report.plan_status;
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

  void AgentProgress::restore(std::string_view final_message) {
    if (final_message_.view().empty()) {
      final_message_.assign(utf8Prefix(final_message, agent_report_message_bytes));
    }
  }

  std::uint16_t AgentProgress::done() const noexcept {
    if (!uses_tasks_) {
      return done_;
    }

    return static_cast<std::uint16_t>(std::ranges::count_if(tasks_.view().first(count_), [](const Task& task) {
      return task.status == AgentPlanStatus::completed;
    }));
  }

  std::uint16_t AgentProgress::total() const noexcept {
    if (!uses_tasks_) {
      return total_;
    }

    return static_cast<std::uint16_t>(std::ranges::count_if(tasks_.view().first(count_), [](const Task& task) {
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
        pending = task.subject.view();
        break;
      }

      if (task.status == AgentPlanStatus::pending && pending.empty()) {
        pending = task.subject.view();
      }
    }

    return pending;
  }

  std::string_view AgentProgress::finalMessage() const noexcept {
    return final_message_.view();
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
    session = {};
    path = {};
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

  Agent::Agent(PaneKey key)
      : pane(key.id),
        generation(key.generation) {}

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
      // The screen showed the turn end before its Stop came: the turn finished, it was not stopped.
      if (incoming.state == AgentReportState::ready && screen_ended_turn) {
        acknowledged = false;
      }

      screen_ended_turn = false;
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
      evidence.screen_current = false;
      evidence.report.reset();
      evidence.work.reset();
      evidence.settled = AgentStatus::unknown;
      evidence.hooks_seen = false;
      unreported_work_at.reset();
      screen_ended_turn = false;
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

    if (signal.status == AgentStatus::unknown) {
      return project(now.milliseconds);
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
    // The screen over a report that holds, or a report of a stopped turn: idle, nothing new to read.
    const bool over_report = selected->source == AgentSource::screen && evidence.activeReport(now).hasValue();
    const bool stopped = over_report || (selected->source == AgentSource::lifecycle_report && evidence.report_state == AgentReportState::interrupted);

    // New work replaces the result the user has not seen; a question or a failure in between does not.
    if (next_status == AgentStatus::working) {
      acknowledged = true;
      screen_ended_turn = false;
    } else if (next_status == AgentStatus::ready) {
      if (status == AgentStatus::working && !stopped) {
        acknowledged = false;
      }

      if (status == AgentStatus::working && over_report) {
        screen_ended_turn = true;
      }

      next_status = acknowledged ? AgentStatus::ready : AgentStatus::done;
    }

    const auto next_provider = projectedProvider(evidence, *selected);
    const auto next_reason = projectedReason(next_status, evidence, *selected);
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

    // Control characters: C0 and DEL.
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_byte = 0x7f;

    validateUtf8(value);
    if (value.size() > agent_report_title_bytes || std::ranges::any_of(value, [](unsigned char byte) {
          return byte < first_printable || byte == delete_byte;
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
        records_(memory) {
    records_.reserve(capacity);
  }

  template <Allocator Memory>
  const Agent* AgentRegistry<Memory>::find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    for (const auto& agent : records_) {
      if (agent->pane == pane && agent->generation == generation) {
        return &agent.get();
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  Agent* AgentRegistry<Memory>::findMut(std::uint64_t pane, std::uint64_t generation) noexcept {
    for (auto& agent : records_.viewMut()) {
      if (agent->pane == pane && agent->generation == generation) {
        return &agent.getMut();
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  Agent& AgentRegistry<Memory>::ensure(std::uint64_t pane, std::uint64_t generation) {
    if (auto* existing = findMut(pane, generation)) {
      return *existing;
    }

    if (records_.size() == capacity) {
      throw RequestError{FailureCode::resource_limit, "Agent capacity reached"};
    }

    records_.push(ds::makeBox<Agent>(memory_, PaneKey{.id = pane, .generation = generation}));
    return records_.backMut().getMut();
  }

  template <Allocator Memory>
  std::span<const ds::Box<Agent, Memory>> AgentRegistry<Memory>::records() const noexcept {
    return std::span{records_};
  }

  template <Allocator Memory>
  std::span<ds::Box<Agent, Memory>> AgentRegistry<Memory>::recordsMut() noexcept {
    return records_.viewMut();
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
      : path_(memory),
        bytes_(memory),
        decoded_(memory) {}

  template <Allocator Memory>
  auto SessionFileReader<Memory>::observe(const Request& request) noexcept -> Result {
    TELAR_TRACE("agents.readSessionTitle");
    Result result{.request = request, .offset = request.watch.offset, .title = ds::none};

    try {
      path_.assign(request.watch.path.view());
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
      case AgentSessionFileKind::antigravity_annotations:
        antigravity(request.watch, result);
        break;
      }
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): the title is best effort, and a session file that cannot be read yields what was read before it failed
    }

    return result;
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::stop() noexcept {}

  template <Allocator Memory>
  void SessionFileReader<Memory>::codex(const SessionFileWatch& watch, Result& result) {
    Database database{path_.data(), DatabaseAccess::read_only};
    Statement statement{database, "SELECT name FROM threads WHERE id = ?1"};

    statement.bind(1, watch.session.view());
    if (statement.next()) {
      result.title.emplace().assign(utf8Prefix(statement.text(0), title_capacity));
    }
  }

  template <Allocator Memory>
  bool SessionFileReader<Memory>::cursorPath(std::string_view path, std::string_view session) noexcept {
    if (session.empty() || session.size() > agent_report_session_bytes || !std::ranges::all_of(session, [](char byte) {
          return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-';
        })) {
      return false;
    }

    if (!path.ends_with("/meta.json")) {
      return false;
    }

    path.remove_suffix(sizeof("/meta.json") - 1);
    return textAfter(path, path.rfind('/') + 1) == session;
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::cursor(const SessionFileWatch& watch, Result& result) {
    if (!cursorPath(path_, watch.session.view())) {
      return;
    }

    FileDescriptor file{::open(path_.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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
  bool SessionFileReader<Memory>::antigravityPath(std::string_view path, std::string_view session) noexcept {
    constexpr std::string_view directory = "/annotations/";
    constexpr std::string_view extension = ".pbtxt";

    if (session.empty() || session.size() > agent_report_session_bytes || !std::ranges::all_of(session, [](char byte) {
          return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F') || byte == '-';
        })) {
      return false;
    }

    if (!path.starts_with('/') || !path.ends_with(extension)) {
      return false;
    }

    path.remove_suffix(extension.size());
    return path.ends_with(session) && path.substr(0, path.size() - session.size()).ends_with(directory);
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::antigravity(const SessionFileWatch& watch, Result& result) {
    if (!antigravityPath(path_, watch.session.view())) {
      return;
    }

    FileDescriptor file{::open(path_.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    const auto size = regularFileSize(file);
    if (!size || *size >= metadata_capacity) {
      return;
    }

    const auto input = read(file.get(), 0, metadata_capacity);
    if (input.size() == metadata_capacity) {
      return;
    }

    result.title = annotationTitle(input);
  }

  template <Allocator Memory>
  ds::Option<FixedText<agent_report_title_bytes>> SessionFileReader<Memory>::annotationTitle(std::string_view input) {
    validateUtf8(input);

    // A quoted string from its opening quote, into decoded_: the index after its closing quote.
    // Antigravity escapes a quote and a backslash; a title with any other escape is a control
    // byte the agent's title refuses, so it fails here.
    const auto quoted = [&](std::size_t start) {
      const char quote = input[start];

      decoded_.truncate(0);
      for (auto index = start + 1; index < input.size(); ++index) {
        const char byte = input[index];
        if (byte == quote) {
          return index + 1;
        }

        if (byte == '\\') {
          if (++index == input.size() || (input[index] != '"' && input[index] != '\'' && input[index] != '\\')) {
            throw EncodingError{"Unsupported annotation escape"};
          }
        } else if (byte == '\n') {
          break;
        }

        decoded_.push(input[index]);
      }

      throw EncodingError{"Unterminated annotation string"};
    };

    const auto identifier = [](char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_';
    };

    ds::Option<FixedText<agent_report_title_bytes>> title;
    std::size_t depth = 0;

    for (std::size_t index = 0; index < input.size();) {
      const char byte = input[index];

      if (byte == '"' || byte == '\'') {
        index = quoted(index);
      } else if (byte == '#') {
        const auto end = input.find('\n', index);

        index = end == std::string_view::npos ? input.size() : end;
      } else if (byte == '{' || byte == '<') {
        ++depth;
        ++index;
      } else if (byte == '}' || byte == '>') {
        if (depth-- == 0) {
          throw EncodingError{"Unbalanced annotation"};
        }

        ++index;
      } else if (identifier(byte)) {
        const auto start = index;

        while (index < input.size() && identifier(input[index])) {
          ++index;
        }

        if (depth != 0 || input.substr(start, index - start) != "title") {
          continue;
        }

        index = input.find_first_not_of(" \t\r\n", index);
        if (index == std::string_view::npos || input[index] != ':') {
          throw EncodingError{"Annotation title without a value"};
        }

        index = input.find_first_not_of(" \t\r\n", index + 1);
        if (index == std::string_view::npos || (input[index] != '"' && input[index] != '\'')) {
          throw EncodingError{"Annotation title is not a string"};
        }

        if (title) {
          throw EncodingError{"Duplicate annotation title"};
        }

        index = quoted(index);
        title.emplace().assign(utf8Prefix(decoded_, title_capacity));
      } else {
        ++index;
      }
    }

    if (depth != 0) {
      throw EncodingError{"Unbalanced annotation"};
    }

    // An annotation without a title clears the agent's, as Cursor's metadata does.
    return title ? title : ds::Option{FixedText<agent_report_title_bytes>{}};
  }

  template <Allocator Memory>
  void SessionFileReader<Memory>::claude(const SessionFileWatch& watch, Result& result) {
    FileDescriptor file{::open(path_.data(), combineFlags(O_RDONLY, O_NONBLOCK, O_CLOEXEC))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
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
      if (line.size() > line_capacity || !line.starts_with(R"({"type":"custom-title")")) {
        continue;
      }

      try {
        if (const auto title = readTitle(line, watch.session.view())) {
          result.title = title;
        }
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a title line that does not parse is skipped, as the lines that are no title are
      }
    }

    result.offset = from + (consumed == 0 && input.size() == transcript_capacity ? input.size() : consumed);
  }

  template <Allocator Memory>
  ds::Option<FixedText<agent_report_title_bytes>> SessionFileReader<Memory>::readTitle(std::string_view input, ds::Option<std::string_view> session) {
    validateUtf8(input);
    const auto object = JsonValue::parse(input);
    FixedText<agent_report_title_bytes> title;
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

      const auto count = ::pread(descriptor, bytes_.viewMut().subspan(filled).data(), limit - filled, static_cast<off_t>(offset + filled));
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
