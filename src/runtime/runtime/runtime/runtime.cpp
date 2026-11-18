module;
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.runtime.runtime;

import telar.ghostty.vt;
import telar.sys.process;
import telar.platform.error;
import telar.platform.paths;
import telar.plugins;
import telar.runtime.platform.git_status;
import telar.runtime.terminal.text_reader;
import telar.base.editors;
import telar.base.text.utf8;
import telar.runtime.platform.launch_program;
import telar.runtime.suggestions.engine;
import telar.runtime.diagnostics.line;
import telar.base.ds;

namespace telar::runtime {

  void AgentSnapshotBuilder::publish(ClientSession& client, const RuntimeModel& model, const AgentRegistry<ConcurrentMemory>& registry) {
    // The entries view the model, the registry and these texts only while the snapshot is sent.
    ds::Array<AgentSnapshotEntry, AgentRegistry<ConcurrentMemory>::capacity> entries;
    auto& directories = directories_;
    auto& placeholders = placeholders_;
    std::size_t count = 0;
    const auto now = wallMilliseconds();

    for (const auto& agent : registry.records()) {
      const auto* pane = model.panes.find(agent->pane);
      if (pane == nullptr || pane->generation != agent->generation || agent->sequence == 0) {
        continue;
      }

      const auto* workspace = model.workspaces.find(pane->location.workspace.id);
      const auto* tab = workspace == nullptr ? nullptr : workspace->tab(pane->location.tab_id);
      if (tab == nullptr) {
        continue;
      }

      const auto position = std::find(tab->panes.begin(), tab->panes.end(), pane->id);
      if (position == tab->panes.end()) {
        continue;
      }

      auto provider = describeProvider(agent->provider);
      const auto* manifest = model.manifests.find(agent->provider);
      if (manifest != nullptr) {
        provider = {.name = manifest->name.view(), .display_name = manifest->displayName(), .placeholder = manifest->placeholderTitle(placeholders.atMut(count)), .attachments = manifest->attachments};
      }

      std::string_view cwd = pane->cwd;
      const auto home = processHome();
      if (!home.empty() && cwd.starts_with(home) && (cwd.size() == home.size() || cwd[home.size()] == '/')) {
        ds::Array<char, 48> shortened{'~'};
        const auto suffix = utf8Prefix(cwd.substr(home.size()), 47);

        std::copy(suffix.begin(), suffix.end(), shortened.dataMut() + 1);
        directories.atMut(count).assign({shortened.data(), suffix.size() + 1});
      } else {
        directories.atMut(count).assign(utf8Prefix(cwd, 48));
      }

      entries.atMut(count) = {
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
          .status_age_s = static_cast<std::uint32_t>(std::clamp<std::int64_t>((now - agent->changed_at) / 1000, 0, std::numeric_limits<std::uint32_t>::max())),
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

  template <EventLoop Poller, HistoryEventSink History>
  AgentService<Poller, History>::AgentService(ConcurrentMemory& memory)
      : agents_(memory) {}

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::enableDescriptions(bool enabled) noexcept {
    descriptions_.enable(enabled);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::observeInput(const Pane& pane, std::span<const Byte> bytes) {
    if (descriptions_.enabled()) {
      if (auto* agent = agents_.find(pane.id, pane.generation)) {
        agent->observeInput(bytes);
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  ds::Option<DescriptionRequest> AgentService<Poller, History>::nextDescription() {
    return descriptions_.nextDescription(agents_);
  }

  template <EventLoop Poller, HistoryEventSink History>
  ds::Option<HistorySessionTitle> AgentService<Poller, History>::completeDescription(const DescriptionResult& result) {
    return descriptions_.completeDescription(agents_, result);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::report(RuntimeModel& model, ClientSession& client, const ReportAgent& request) {
    auto& pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto* existing = agents_.find(pane.id, pane.generation);
    if (existing == nullptr && request.state == AgentReportState::continuing) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (existing == nullptr) {
      existing = &ensure(pane);
    }

    auto& agent = *existing;
    const auto previous = agent.status;
    const auto previous_watch = agent.file_watch.revision;
    const bool changed = agent.report(request, client.deferred_report.reportTime());

    if (agent.file_watch.revision != previous_watch) {
      agent.file_watch.revision = ++session_watch_revision_;
      has_session_files_ = true;
    }

    if (changed) {
      if (alerts(agent, previous)) {
        sounds_.push(agent);
      }

      projected(agent.pane, agent.generation);
    }

    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::reportSession(RuntimeModel& model, ClientSession& client, const ReportAgentSession& request) {
    auto& pane = require(model.panes, request.pane_id, request.pane_generation);

    ensure(pane).setSession(request.session);
    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::reportTitle(RuntimeModel& model, ClientSession& client, const ReportAgentTitle& request) {
    auto& pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto& agent = ensure(pane);

    agent.evidence.claim(request.provider);
    if (agent.reportTitle(request.title)) {
      agents_.changed();
    }

    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <EventLoop Poller, HistoryEventSink History>
  ds::Option<SessionFileRequest> AgentService<Poller, History>::nextSessionFile(std::chrono::steady_clock::time_point now) const {
    if (!has_session_files_) {
      return ds::none;
    }

    const Agent* selected = nullptr;

    for (const auto& agent : agents_.records()) {
      const auto& watch = agent->file_watch;
      if (watch.path.view().empty() || now - watch.checked_at < std::chrono::seconds{1}) {
        continue;
      }

      if (selected == nullptr || watch.checked_at < selected->file_watch.checked_at) {
        selected = agent.get();
      }
    }

    return selected == nullptr ? ds::none : ds::Option{SessionFileRequest{selected->pane, selected->generation, selected->file_watch}};
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::completeSessionFile(const SessionFileResult& result, std::chrono::steady_clock::time_point now) {
    auto* agent = agents_.find(result.request.pane, result.request.generation);
    if (agent == nullptr) {
      return;
    }

    auto& watch = agent->file_watch;
    const auto& requested = result.request.watch;
    if (watch.revision != requested.revision || watch.path.view() != requested.path.view() || watch.session.view() != requested.session.view()) {
      return;
    }

    watch.checked_at = now;
    watch.offset = result.offset;
    if (result.title && watch.remember(result.title->view())) {
      try {
        if (agent->reportTitle(result.title->view())) {
          agents_.changed();
        }
      } catch (const std::exception&) {
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::reportProgress(RuntimeModel& model, ClientSession& client, const ReportAgentProgress& request) {
    auto& pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto& agent = ensure(pane);

    agent.evidence.claim(request.provider);
    const bool applied = agent.progress.apply(request);

    if (!request.cwd.empty()) {
      const auto* worktree = model.worktrees.containing(request.cwd);
      if (worktree != nullptr) {
        agent.worktree = worktree->id;
      } else if (!request.work_tree_path.empty()) {
        const auto branch = request.work_tree_branch.empty() ? request.work_tree_path.substr(request.work_tree_path.rfind('/') + 1) : request.work_tree_branch;
        const auto result = model.worktrees.registerEntry(RegisterWorktree{.source = model.worktrees.sourceFor(pane.location.workspace.id), .created_by = pane.id, .origin = WorktreeOrigin::external, .path = request.work_tree_path, .branch = branch});

        agent.worktree = result.worktree;
        ++model.workspace_revision;
      } else {
        agent.worktree = 0;
      }
    }

    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
    return applied;
  }

  template <EventLoop Poller, HistoryEventSink History>
  tbc::view<Pane&, tbc::lt::a> AgentService<Poller, History>::validateCommand(tbc::view<RuntimeModel&, tbc::lt::a> model, ClientSession& client, const ReportAgentCommand& request) {
    return authorize(model.panes, client, request.pane_id, request.pane_generation, model.manifests.named(request.provider));
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::sendText(RuntimeModel& model, Panes& panes, ClientSession& client, const SendPaneText& request, bool focused) {
    auto& pane = Panes::requireGeneration(model.panes, request.pane_id, request.pane_generation);
    if (pane.exit_status || pane.output_closed) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (focused) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }

    if (request.mode == PaneTextMode::prompt && blocked(pane)) {
      throw RequestError{FailureCode::agent_blocked, "Agent is waiting for a decision"};
    }

    ds::Array<char, 192> prefix{};
    std::size_t length = 0;
    const auto* sender = request.sender ? model.panes.find(*request.sender) : nullptr;
    if (request.mode == PaneTextMode::prompt && sender != nullptr) {
      if (!prompt_budget_.spend(sender->id, pane.id, std::chrono::steady_clock::now())) {
        throw RequestError{FailureCode::prompt_rate_limited, "Prompt budget for this pane is spent; wait for its answer"};
      }

      std::string_view name = "a telar pane";

      if (const auto* workspace = model.workspaces.find(sender->location.workspace.id)) {
        name = workspace->displayName();
      }

      for (const auto* worktree : model.worktrees.items()) {
        if (worktree != nullptr && worktree->workspace == sender->location.workspace.id) {
          name = worktree->branch.view();
          break;
        }
      }

      name = utf8Prefix(name, 64);
      length = static_cast<std::size_t>(std::snprintf(prefix.dataMut(), prefix.size(), "[telar: from %.*s, pane %llu] ", static_cast<int>(name.size()), name.data(), static_cast<unsigned long long>(sender->id)));
    }

    panes.sendText(model.panes, client, request, {prefix.data(), length}, [this](const Pane& target, std::span<const Byte> bytes) {
      observeInput(target, bytes);
    });
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::acknowledge(const AcknowledgeAgent& request) noexcept {
    if (auto* agent = agents_.find(request.pane_id, request.pane_generation); agent != nullptr && agent->status == AgentStatus::done) {
      agent->acknowledged = true;
      if (agent->project(wallMilliseconds())) {
        projected(agent->pane, agent->generation);
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::interrupt(RuntimeModel& model, Panes& panes, ClientSession& client, const InterruptAgent& request, bool focused) {
    auto& pane = Panes::requireGeneration(model.panes, request.pane_id, request.pane_generation);
    if (pane.exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (focused) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }

    auto* agent = agents_.find(pane.id, pane.generation);
    const auto now = std::chrono::steady_clock::now();
    if (agent != nullptr && agent->interrupt_at && now - *agent->interrupt_at < std::chrono::seconds{2}) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (agent == nullptr || agent->status != AgentStatus::working) {
      throw RequestError{FailureCode::agent_not_working, "Agent is not working"};
    }

    const auto* manifest = model.manifests.find(agent->provider);
    if (manifest == nullptr || manifest->interrupt == AgentInterruptKey::none) {
      throw RequestError{FailureCode::interrupt_unsupported, "Agent declares no interrupt key"};
    }

    ds::Array<Byte, 128> encoded;
    const bool control_c = manifest->interrupt == AgentInterruptKey::control_c;
    const auto bytes = pane.terminal.encodeKey(control_c ? GHOSTTY_KEY_C : GHOSTTY_KEY_ESCAPE, control_c ? GHOSTTY_MODS_CTRL : 0, encoded.viewMut());
    const auto repeats = manifest->interrupt == AgentInterruptKey::escape_twice ? 2 : 1;
    if (panes.admitInput(pane, bytes.size() * repeats)) {
      for (int index = 0; index < repeats; ++index) {
        pane.enqueueInput(bytes);
      }

      panes.flushInput(pane);
    }

    agent->report(ReportAgent{.state = AgentReportState::settling, .event = "Interrupted by telar"});
    agent->interrupt_at = now;
    agent->interrupt_revision = pane.terminal.contentRevision();
    projected(agent->pane, agent->generation);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::focused(const ClientStore& clients, const ClientLayouts& layouts, std::uint64_t pane) noexcept {
    for (const auto* client : clients.items()) {
      if (client != nullptr && client->role == ClientRole::interactive && !client->connection.closing && layouts.focusedPane(client->identity) == pane) {
        return true;
      }
    }

    return false;
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::blocked(const Pane& pane) const noexcept {
    const auto* agent = agents_.find(pane.id, pane.generation);

    return agent != nullptr && agent->status == AgentStatus::blocked;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::query(const RuntimeModel& model, ClientSession& client) {
    snapshots_.publish(client, model, agents_);
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t AgentService<Poller, History>::revision() const noexcept {
    return agents_.revision();
  }

  template <EventLoop Poller, HistoryEventSink History>
  const Agent* AgentService<Poller, History>::find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    return agents_.find(pane, generation);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::observeProcess(Pane& pane, ds::Option<ProcessIdentity> identity, AgentProvider provider) {
    auto* agent = agents_.find(pane.id, pane.generation);
    if (agent != nullptr && agent->process_identity && provider == AgentProvider::unknown) {
      agents_.removeIf([&](const Agent& record) {
        return record.pane == pane.id && record.generation == pane.generation;
      });

      return;
    }

    if (!identity || provider == AgentProvider::unknown) {
      return;
    }

    if (agent == nullptr) {
      if (agents_.records().size() == AgentRegistry<ConcurrentMemory>::capacity) {
        return;
      }

      agent = &ensure(pane);
    }

    const bool changed = agent->observeProcess(*identity, provider);

    if (pane.restored_agent) {
      const auto& restored = *pane.restored_agent;
      if (restored.provider == provider) {
        agent->setSession(restored.session.view());
        agent->title.assign(restored.title.view());
        agent->title_source = restored.title_source;
        agent->in_pane = restored.in_pane;
        agent->title_state = restored.title.view().empty() ? AgentTitleState::placeholder : AgentTitleState::ready;
        if (!restored.title.view().empty()) {
          agent->finishTitleCapture();
        }

        agents_.changed();
      }

      pane.restored_agent.reset();
    }

    if (changed) {
      projected(pane.id, pane.generation);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::observeProcess(Pane& pane, const ProcessProbeResult& observation) {
    observeProcess(pane, observation.identity, observation.provider);
    auto* agent = agents_.find(pane.id, pane.generation);
    if (agent == nullptr) {
      return;
    }

    if (observation.shell_foreground) {
      agents_.removeIf([&](const Agent& record) {
        return record.pane == pane.id && record.generation == pane.generation;
      });

      return;
    }

    if (agent->setProcessContext(observation.session_host, observation.hooks_installed, observation.agent_identity)) {
      if (agent->project(wallMilliseconds())) {
        projected(agent->pane, agent->generation);
      } else {
        agents_.changed();
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::observeScreen(Pane& pane, const AgentSignal& signal, ObservationTime time) {
    auto* agent = agents_.find(pane.id, pane.generation);
    if (agent == nullptr) {
      return;
    }

    const auto previous = agent->status;

    if (agent->observeScreen(signal, time)) {
      if (alerts(*agent, previous)) {
        sounds_.push(*agent);
      }

      projected(agent->pane, agent->generation);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::refresh(RuntimeModel& model, Panes& panes, const ClientStore& clients, const ClientLayouts& layouts, std::chrono::steady_clock::time_point now) {
    agents_.removeIf([&](const Agent& agent) {
      return findPane(model.panes, agent.pane, agent.generation) == nullptr || (!agent.evidence.choose(wallMilliseconds()) && agent.observed_at != 0);
    });

    for (auto* pane : model.panes.items()) {
      if (pane == nullptr || pane->exit_status) {
        continue;
      }

      auto* agent = agents_.find(pane->id, pane->generation);
      if (agent == nullptr) {
        continue;
      }

      if (agent->cwd_revision != pane->cwd_revision || agent->title_revision != pane->terminal.effects.title_revision) {
        agent->cwd_revision = pane->cwd_revision;
        agent->title_revision = pane->terminal.effects.title_revision;
        agents_.changed();
      }

      const bool settled = agent->interrupt_at && settleInterrupt(panes, focused(clients, layouts, pane->id), *pane, *agent, now);
      const auto current_time = wallMilliseconds();

      agent->evidence.expire(current_time);
      if (!agent->evidence.report) {
        agent->interrupt_at.reset();
        agent->interrupt_idle_at.reset();
      }

      if (agent->project(current_time) || settled) {
        projected(agent->pane, agent->generation);
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  Agent& AgentService<Poller, History>::ensure(Pane& pane) {
    auto& agent = agents_.ensure(pane.id, pane.generation);

    agent.session_id = pane.history_session;
    return agent;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::deliverSounds(ClientStore& clients) noexcept {
    for (const auto& notification : sounds_.queued()) {
      broadcast(clients, [](const ClientSession& client) {
        return client.subscribed;
      },
          notification);
    }

    sounds_.clear();
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::projected(std::uint64_t pane, std::uint64_t generation) noexcept {
    const auto pending = DescriptionQueue::pending(agents_);

    if (auto* agent = agents_.find(pane, generation)) {
      descriptions_.project(pending, *agent);
      agent->sequence = ++sequence_;
    }

    agents_.changed();
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::alerts(const Agent& agent, AgentStatus previous) noexcept {
    return (agent.status == AgentStatus::done && previous == AgentStatus::working) || (agent.status == AgentStatus::blocked && previous != AgentStatus::blocked);
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::settleInterrupt(Panes& panes, bool focused, Pane& pane, Agent& agent, std::chrono::steady_clock::time_point now) {
    bool settled = false;

    if (hasIdleScreen(agent.provider)) {
      if (pane.terminal.contentRevision() <= agent.interrupt_revision || !pane.terminal.outputSettled()) {
        return false;
      }

      pane.terminal.refresh();
      const auto observation = AgentScreenReader{pane.terminal}.observe(agent.provider);
      if (observation.restored_draft && !agent.interrupt_draft_cleared && !focused) {
        ds::Array<Byte, 128> encoded;
        const auto bytes = pane.terminal.encodeKey(GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL, encoded.viewMut());
        if (panes.admitInput(pane, bytes.size())) {
          pane.enqueueInput(bytes);
          panes.flushInput(pane);
        }

        agent.interrupt_draft_cleared = true;
        agent.interrupt_at = now;
        agent.interrupt_idle_at.reset();
        agent.interrupt_revision = pane.terminal.contentRevision();
        return false;
      }

      if (observation.status != AgentStatus::ready || observation.restored_draft) {
        agent.interrupt_idle_at.reset();
        return false;
      }

      if (!agent.interrupt_idle_at) {
        agent.interrupt_idle_at = now;
      }

      settled = now - *agent.interrupt_idle_at >= std::chrono::milliseconds{500};
    } else {
      settled = now - *agent.interrupt_at >= std::chrono::seconds{3};
    }

    if (settled) {
      agent.interrupt_at.reset();
      agent.interrupt_idle_at.reset();
      agent.evidence.report.reset();
      if (hasIdleScreen(agent.provider)) {
        agent.evidence.applyScreen(AgentSignal{agent.provider, AgentStatus::ready, 94, true, true}, ObservationTime::now(), agent.status, false);
      }

      return agent.project(wallMilliseconds());
    }

    return false;
  }

  template <EventLoop Poller, HistoryEventSink History>
  Pane& AgentService<Poller, History>::require(PaneStore& panes, std::uint64_t identity, std::uint64_t generation) {
    auto& pane = Panes::requireGeneration(panes, identity, generation);
    if (generation == 0 || pane.exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }

    return pane;
  }

  template <EventLoop Poller, HistoryEventSink History>
  tbc::view<Pane&, tbc::lt::a> AgentService<Poller, History>::authorize(tbc::view<PaneStore&, tbc::lt::a> panes, const ClientSession& client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider) {
    TELAR_TRACE("agents.authorize");
    auto& pane = require(panes, pane_id, generation);

    if (provider == AgentProvider::unknown) {
      return pane;
    }

    if (!client.verifiedFor(pane)) {
      throw RequestError{FailureCode::foreign_process, "The report does not come from this pane's agent"};
    }

    if (const auto* agent = agents_.find(pane.id, pane.generation); agent != nullptr && !agent->evidence.accepts(provider)) {
      throw RequestError{FailureCode::foreign_process, "The report belongs to another agent"};
    }

    return pane;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::SoundQueue::push(const Agent& agent) noexcept {
    if (count_ < entries_.size()) {
      entries_.atMut(count_++) = AgentSoundNotification{
          .pane_id = agent.pane,
          .pane_generation = agent.generation,
          .sound = agent.status == AgentStatus::blocked ? AgentSound::needs_input : AgentSound::ready,
      };
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::span<const AgentSoundNotification> AgentService<Poller, History>::SoundQueue::queued() const noexcept {
    return std::span{entries_}.first(count_);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::SoundQueue::clear() noexcept {
    count_ = 0;
  }

  template class AgentService<NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
  template class AgentService<NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  void ownDirectory(tbc::view<Launch&, tbc::lt::a> launch, tbc::view<LaunchDirectory&, tbc::lt::a> storage, std::string_view directory) {
    if (directory.size() > 4096) {
      throw RequestError{FailureCode::invalid_request, "working directory is too long"};
    }

    storage.assign(directory);
    launch.cwd = storage.view();
  }

  tbc::view<Launch, tbc::lt::a> resolveLaunchDirectory(const RuntimeModel& model, const ClientSession& client, tbc::view<Launch, tbc::lt::a> launch, tbc::view<LaunchDirectory&, tbc::lt::a> directory, LaunchDirectoryScope scope) {
    if (launch.cwd_source == 0) {
      return launch;
    }

    const auto* pane = model.panes.find(launch.cwd_source);
    if (client.attachment(launch.cwd_source) == nullptr || pane == nullptr || pane->close_requested || pane->exit_status) {
      throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
    }

    const auto* workspace = std::get_if<WorkspaceLocation>(&scope);
    const auto* tab = std::get_if<TabLocation>(&scope);
    if (tab != nullptr) {
      workspace = &tab->workspace;
    }

    if (workspace != nullptr && (workspace->kind != pane->location.workspace.kind || workspace->id != pane->location.workspace.id)) {
      throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
    }

    if (tab != nullptr && tab->tab_id != pane->location.tab_id) {
      throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
    }

    ownDirectory(launch, directory, pane->cwd);
    launch.cwd_source = 0;
    return launch;
  }

  PluginDelivery::PluginDelivery(LimitService& limits) noexcept
      : limits_(limits) {}

  void PluginDelivery::reportMetrics(const plugins::TapMetrics& now) {
    reportGrowth(now.dropped_queue, previous_.dropped_queue, {"plugins.tap.queue_depth", "exchanges", plugins::Limits::queue_depth});
    reportGrowth(now.dropped_bytes, previous_.dropped_bytes, {"plugins.tap.max_held_bytes", "bytes", plugins::Limits::held_bytes});
    reportGrowth(now.timeouts, previous_.timeouts, {"plugins.tap.reply_timeout_ms", "ms", std::chrono::duration_cast<std::chrono::milliseconds>(plugins::Limits::reply_deadline).count()});
    reportGrowth(now.disabled, previous_.disabled, {"plugins.tap.restart_limit", "restarts in 10 min", plugins::Limits::restarts});
    previous_ = now;
  }

  void PluginDelivery::publish(ClientStore& clients, const NotificationBody& body) {
    const Notification notification{body};
    ds::Array<Byte, validation_bytes> validation;
    std::span<Byte> remaining{validation.viewMut()};

    try {
      Codec::encode(notification, remaining);
    } catch (const EncodingError&) {
      return;
    }

    ClientControl::publish(clients, notification);
  }

  void PluginDelivery::reportGrowth(std::uint64_t current, std::uint64_t previous, const LimitReach& reach) {
    if (current > previous) {
      limits_.report(reach);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  WorkspaceService<Poller, History>::WorkspaceService(ConcurrentMemory& memory)
      : memory_(memory) {}

  template <EventLoop Poller, HistoryEventSink History>
  Workspace& WorkspaceService<Poller, History>::require(WorkspaceStore& workspaces, WorkspaceLocation location) {
    auto* workspace = workspaces.find(location.id);
    if (location.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
    }

    return *workspace;
  }

  template <EventLoop Poller, HistoryEventSink History>
  Tab& WorkspaceService<Poller, History>::requireTab(WorkspaceStore& workspaces, TabLocation location) {
    auto* tab = require(workspaces, location.workspace).tabMut(location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    return *tab;
  }

  template <EventLoop Poller, HistoryEventSink History>
  tbc::view<const ConfigureTerminalColors*, tbc::lt::a> WorkspaceService<Poller, History>::ownerColors(const WorkspaceStore& workspaces, tbc::view<const ClientStore&, tbc::lt::a> clients, std::uint64_t workspace) noexcept {
    const auto* found = workspaces.find(workspace);
    const auto* owner = found != nullptr && found->geometry_client ? clients.find(*found->geometry_client) : nullptr;

    return owner == nullptr ? nullptr : &owner->colors;
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool WorkspaceService<Poller, History>::ownerBarePrompt(const WorkspaceStore& workspaces, const ClientStore& clients, std::uint64_t workspace) noexcept {
    const auto* found = workspaces.find(workspace);
    const auto* owner = found != nullptr && found->geometry_client ? clients.find(*found->geometry_client) : nullptr;

    return owner != nullptr && owner->bare_prompt;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::open(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const OpenPane& request) {
    ds::Option<std::uint64_t> pane;
    bool created = false;

    if (request.target.kind == PaneTarget::Kind::pane) {
      const auto& target = Panes::require(model.panes, request.target.id);
      if (target.close_requested || target.exit_status) {
        throw RequestError{FailureCode::pane_not_found, "pane not found"};
      }

      pane = target.id;
    } else if (request.target.kind == PaneTarget::Kind::workspace) {
      pane = firstPane(model.panes, require(model.workspaces, WorkspaceLocation{.id = request.target.id}));
    } else {
      if (!request.launch) {
        throw RequestError{FailureCode::invalid_request, "default pane launch is missing"};
      }

      LaunchDirectory directory;
      auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), *request.launch, directory);
      const Workspace* workspace = nullptr;

      for (const auto* candidate : model.workspaces.items()) {
        if (candidate != nullptr && candidate->path == launch.cwd) {
          workspace = candidate;
          break;
        }
      }

      if (workspace != nullptr) {
        pane = firstPane(model.panes, *workspace);
        if (!pane && !workspace->tabs.empty()) {
          pane = createAt(model, panes, clients, client_id, TabLocation{WorkspaceLocation{.id = workspace->id}, workspace->tabs.front().id}, launch, request.size);
          created = true;
        }
      } else {
        pane = createRoot(model, panes, clients, client_id, launch, request.size, {});
        created = true;
      }
    }

    if (!pane) {
      throw RequestError{FailureCode::pane_not_found, "workspace has no running pane"};
    }

    auto& client = requireClient(clients, client_id);

    panes.attach(model, client, *pane, request.size);
    sendOpened(client, request.request_id, Panes::require(model.panes, *pane), created);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createWorkspace(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const CreateWorkspace& request) {
    LaunchDirectory directory;
    auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), request.launch, directory);

    if (request.create_cwd && request.launch.cwd_source == 0) {
      createDirectories(launch.cwd);
    }

    const auto pane = createRoot(model, panes, clients, client_id, launch, request.size, request.name, true);

    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createTab(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const CreateTab& request) {
    if (!acquireGeometry(model.panes, model.metrics, requireClient(clients, client_id), require(model.workspaces, request.workspace))) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }

    LaunchDirectory directory;
    const auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), request.launch, directory, request.workspace);
    auto& workspace = require(model.workspaces, request.workspace);
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity(model);

    workspace.tabs.emplace(memory_, tab_id, request.label);

    try {
      const auto pane = createAt(model, panes, clients, client_id, TabLocation{request.workspace, tab_id}, launch, request.size);

      ++model.next_tab_id;
      const auto& opened = Panes::require(model.panes, pane);
      const auto& tabs = require(model.workspaces, request.workspace).tabs;

      requireClient(clients, client_id).connection.send(TabCreated{
          .request_id = request.request_id,
          .location = opened.location,
          .position = static_cast<std::uint16_t>(tabs.size() - 1),
          .label = tabs.back().label,
          .root_pane_id = opened.id,
          .pane_generation = opened.generation,
      });
    } catch (...) {
      if (auto* current = model.workspaces.find(request.workspace.id); current != nullptr && current->tabs.back().panes.empty()) {
        current->tabs.truncate(current->tabs.size() - 1);
      }

      throw;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t WorkspaceService<Poller, History>::launchBackground(RuntimeModel& model, Panes& panes, const ConfigureTerminalColors* owner_colors, bool bare_prompt, const LaunchTab& request) {
    if (request.launch.cwd_source != 0) {
      throw RequestError{FailureCode::invalid_request, "A background tab requires an explicit working directory"};
    }

    auto& workspace = require(model.workspaces, WorkspaceLocation{.id = request.workspace});
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity(model);

    workspace.tabs.emplace(memory_, tab_id, request.label);
    try {
      auto launch = request.launch;
      LaunchDirectory directory;

      if (launch.cwd.empty()) {
        ownDirectory(launch, directory, workspace.path);
      }

      const auto pane = panes.launch(model, owner_colors, bare_prompt, launch, TabLocation{.workspace = {.id = request.workspace}, .tab_id = tab_id}, request.size).id;

      require(model.workspaces, WorkspaceLocation{.id = request.workspace}).tabs.backMut().panes.push(pane);
      ++model.next_tab_id;
      ++model.workspace_revision;
      return pane;
    } catch (...) {
      if (auto* current = model.workspaces.find(request.workspace)) {
        current->tabs.truncate(current->tabs.size() - 1);
      }

      throw;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::launchTab(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const LaunchTab& request) {
    const auto pane = launchBackground(model, panes, ownerColors(model.workspaces, clients, request.workspace), ownerBarePrompt(model.workspaces, clients, request.workspace), request);
    const auto& launched = Panes::require(model.panes, pane);

    notify(launched.location.workspace.id, client_id);
    sendOpened(requireClient(clients, client_id), request.request_id, launched, false);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createPane(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const CreatePane& request) {
    const auto* workspace = model.workspaces.find(request.location.workspace.id);
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, request.location))) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    const auto pane = createAt(model, panes, clients, client_id, request.location, request.launch, request.size);

    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::renameWorkspace(RuntimeModel& model, ClientSession& client, const RenameWorkspace& request) {
    require(model.workspaces, request.workspace).name.assign(request.name);
    ++model.workspace_revision;
    notify(request.workspace.id, client.id);
    workspaceSnapshot(model, client, RequestWorkspaceSnapshot{request.request_id, request.workspace});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::renameTab(RuntimeModel& model, ClientSession& client, const RenameTab& request) {
    auto& tab = requireTab(model.workspaces, request.location);

    tab.label.assign(request.label);
    ++model.workspace_revision;
    notify(request.location.workspace.id, client.id);
    client.connection.send(TabRenamed{.request_id = request.request_id, .location = request.location, .label = tab.label});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::moveTab(RuntimeModel& model, ClientSession& client, const MoveTab& request) {
    auto& workspace = require(model.workspaces, request.location.workspace);
    auto* tab = workspace.tab(request.location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    const auto from = static_cast<std::size_t>(tab - workspace.tabs.data());
    auto to = from;

    if (request.relative_to) {
      auto* relative = workspace.tab(*request.relative_to);
      if (relative == nullptr) {
        throw RequestError{FailureCode::tab_not_found, "Relative tab does not exist"};
      }

      to = static_cast<std::size_t>(relative - workspace.tabs.data());
      if (request.direction == TabMoveDirection::previous && from < to) {
        --to;
      }

      if (request.direction == TabMoveDirection::next && from > to) {
        ++to;
      }
    } else if (request.direction == TabMoveDirection::previous && from != 0) {
      to = from - 1;
    } else if (request.direction == TabMoveDirection::next && from + 1 < workspace.tabs.size()) {
      to = from + 1;
    }

    if (from < to) {
      std::rotate(workspace.tabs.dataMut() + from, workspace.tabs.dataMut() + from + 1, workspace.tabs.dataMut() + to + 1);
    } else if (to < from) {
      std::rotate(workspace.tabs.dataMut() + to, workspace.tabs.dataMut() + from, workspace.tabs.dataMut() + from + 1);
    }

    ++model.workspace_revision;
    notify(request.location.workspace.id, client.id);
    client.connection.send(TabMoved{.request_id = request.request_id, .location = request.location, .position = static_cast<std::uint16_t>(to)});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::closePane(RuntimeModel& model, const ClientSession& client, const ClosePane& request) {
    if (client.attachment(request.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "pane not attached"};
    }

    Panes::require(model.panes, request.pane_id).requestClose();
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::collectExited(RuntimeModel& model, Panes& panes, ClientStore& clients) {
    for (std::size_t slot = 0; slot < model.panes.items().size(); ++slot) {
      auto* pane = model.panes.items()[slot];
      if (pane == nullptr || !pane->output_closed || !pane->exit_status || pane->observers != 0) {
        continue;
      }

      retainFinalText(model.exited_panes, *pane);

      const auto location = pane->location;
      const auto identity = pane->id;

      panes.remove(model, clients, identity);
      auto* workspace = model.workspaces.find(location.workspace.id);
      auto* tab = workspace == nullptr ? nullptr : workspace->tabMut(location.tab_id);
      if (tab == nullptr) {
        leaveEmptyViews(model, panes, clients, location.workspace.id);
        continue;
      }

      tab->panes.retain([&](const auto& value) {
        return value != identity;
      });
      releaseEmptyTab(model, panes, clients, location);
      leaveEmptyViews(model, panes, clients, location.workspace.id);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::holdTab(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const HoldTab& request) {
    TELAR_TRACE("runtime.holdTab");
    const auto* workspace = model.workspaces.find(request.location.workspace.id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr || workspace->tab(request.location.tab_id) == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    auto& client = requireClient(clients, client_id);
    if (request.held && !client.held_tabs.insert(request.location)) {
      throw RequestError{FailureCode::resource_limit, "this client holds too many tabs"};
    }

    if (!request.held && client.held_tabs.erase(request.location)) {
      releaseEmptyTab(model, panes, clients, request.location);
    }

    if (auto* current = clients.find(client_id)) {
      current->connection.send(RequestCompleted{.request_id = request.request_id});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::releaseHeldTabs(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id) {
    while (auto* client = clients.find(client_id)) {
      const auto location = client->held_tabs.pop();
      if (!location) {
        return;
      }

      releaseEmptyTab(model, panes, clients, *location);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::closeTab(RuntimeModel& model, ClientSession& client, const CloseTab& request) {
    auto closed = removeTab(model, request.location);

    notify(request.location.workspace.id, client.id, closed.previous_workspace);
    closed.request_id = request.request_id;
    client.connection.send(closed);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::closeWorkspace(RuntimeModel& model, ClientStore& clients, std::uint64_t identity) {
    auto* workspace = model.workspaces.find(identity);

    while (workspace != nullptr && !workspace->tabs.empty()) {
      const auto closed = removeTab(model, TabLocation{WorkspaceLocation{.id = identity}, workspace->tabs.front().id});

      broadcastTabClosed(clients, closed, [](const ClientSession&) {});

      workspace = model.workspaces.find(identity);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::tabSnapshot(RuntimeModel& model, ClientStore& clients, std::uint64_t client_id, const RequestTabSnapshot& request) {
    const auto* workspace = model.workspaces.find(request.location.workspace.id);
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, request.location))) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    requireClient(clients, client_id).connection.defer(request);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::workspaceSnapshot(RuntimeModel& model, ClientSession& client, const RequestWorkspaceSnapshot& request) {
    const auto* workspace = model.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "workspace not found"};
    }

    client.connection.defer(request);
    if (client.role == ClientRole::control && client.subscribed) {
      client.workspace = workspace->id;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::publishList(const RuntimeModel& model, ClientSession& client) {
    ds::Array<WorkspaceListEntry, 64> entries{};
    std::size_t count = 0;

    for (const auto* workspace : model.workspaces.items()) {
      if (workspace != nullptr) {
        entries.atMut(count++) = WorkspaceListEntry{
            .workspace = workspace->id,
            .name = workspace->displayName(),
            .path = workspace->path,
            .tab_count = static_cast<std::uint16_t>(workspace->tabs.size()),
            .branch = workspace->git_branch.view(),
            .dirty = workspace->git_dirty,
        };
      }
    }

    ds::Array<WorktreeListEntry, Worktrees::capacity> worktrees;
    std::size_t worktree_count = 0;

    for (const auto* entry : model.worktrees.items()) {
      if (entry != nullptr) {
        worktrees.atMut(worktree_count++) = entry->entry();
      }
    }

    client.connection.send(WorkspaceList{.revision = model.workspace_revision, .entries = std::span<const WorkspaceListEntry>{entries}.first(count), .worktrees = std::span{worktrees}.first(worktree_count)});
    client.workspace_revision = model.workspace_revision;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::deliverNotices(ClientStore& clients) noexcept {
    if (overflowed_) {
      for (auto* client : clients.items()) {
        if (client != nullptr && client->workspace && client->connection.negotiated && !client->connection.closing) {
          client->workspace_resync = ResyncRequired{.workspace = {.id = *client->workspace}};
        }
      }
    }

    for (const auto& notice : std::span{notices_}.first(notice_count_)) {
      notifyWorkspaceObservers(clients, notice.workspace, notice.origin, notice.previous);
    }

    notice_count_ = 0;
    overflowed_ = false;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::notify(std::uint64_t workspace, std::uint64_t origin, ds::Option<std::uint64_t> previous) noexcept {
    if (notice_count_ == notices_.size()) {
      overflowed_ = true;
      return;
    }

    notices_.atMut(notice_count_++) = {workspace, origin, previous};
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::releaseEmptyTab(RuntimeModel& model, Panes& panes, ClientStore& clients, TabLocation location) {
    auto* workspace = model.workspaces.find(location.workspace.id);
    auto* tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (tab == nullptr || !tab->panes.empty() || tabHeld(clients, location)) {
      return;
    }

    const auto closed = removeTab(model, location);
    ds::Array<std::uint64_t, client_capacity> viewers{};
    std::size_t count = 0;

    broadcastTabClosed(clients, closed, [&](const ClientSession& client) {
      viewers.atMut(count++) = client.id;
    });

    if (closed.workspace_closed) {
      for (const auto viewer : std::span{viewers}.first(count)) {
        panes.detachAll(model, clients, viewer);
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  template <typename Seen>
  void WorkspaceService<Poller, History>::broadcastTabClosed(ClientStore& clients, const TabClosed& closed, Seen&& seen) noexcept {
    deliver(clients, [&](const ClientSession& client) {
      return client.connection.negotiated && client.workspace == closed.location.workspace.id;
    },
        [&](ClientSession& client) {
          seen(client);
          if (!client.connection.trySend(closed)) {
            client.workspace_resync = ResyncRequired{.workspace = closed.location.workspace, .workspace_closed = closed.workspace_closed, .previous_workspace = closed.previous_workspace};
          }
        });
  }

  template <EventLoop Poller, HistoryEventSink History>
  TabClosed WorkspaceService<Poller, History>::removeTab(RuntimeModel& model, TabLocation location) {
    auto* workspace = model.workspaces.find(location.workspace.id);
    auto* tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    const auto previous = workspace->tabs.size() == 1 ? previousWorkspace(model.workspaces, workspace->id) : ds::none;

    for (const auto identity : tab->panes) {
      if (auto* pane = model.panes.find(identity)) {
        pane->requestClose();
      }
    }

    workspace->tabs.retain([&](const auto& candidate) {
      return candidate.id != location.tab_id;
    });

    const bool workspace_closed = workspace->tabs.empty();
    if (workspace_closed) {
      model.workspaces.erase(location.workspace.id);
    }

    ++model.workspace_revision;
    return TabClosed{.location = location, .workspace_closed = workspace_closed, .previous_workspace = previous};
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::leaveEmptyViews(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t workspace) noexcept {
    for (const auto* pane : model.panes.items()) {
      if (pane != nullptr && pane->location.workspace.id == workspace && pane->exit_status) {
        return;
      }
    }

    ds::Array<std::uint64_t, client_capacity> viewers{};
    std::size_t count = 0;

    for (const auto* client : clients.items()) {
      if (client != nullptr && client->workspace == workspace && client->attachments.empty()) {
        viewers.atMut(count++) = client->id;
      }
    }

    for (const auto viewer : std::span{viewers}.first(count)) {
      panes.detachAll(model, clients, viewer);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::retainFinalText(ExitedPanes& exited, Pane& pane) noexcept {
    const auto exit_code = pane.exitCode();

    try {
      TextReader reader{memory_, pane.terminal, ExitedPanes::maximum_bytes};

      reader.read(PaneTextSource::recent, ExitedPanes::kept_rows);
      const auto rows = pane.terminal.totalRows();

      exited.record(pane.id, pane.generation, PaneText{
                                                  .truncated = reader.truncated() || rows > ExitedPanes::kept_rows,
                                                  .text = reader.text(),
                                                  .exit_code = exit_code,
                                              });
    } catch (...) {
      exited.record(pane.id, pane.generation, PaneText{.truncated = true, .exit_code = exit_code});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t WorkspaceService<Poller, History>::createRoot(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const Launch& launch, TerminalSize size, std::string_view name, bool replace_view) {
    if (model.next_tab_id == 0 || model.workspaces.nextCounter() == 0) {
      throw RequestError{FailureCode::resource_limit, "could not create workspace"};
    }

    const auto workspace_id = model.workspaces.nextId();
    auto workspace = makeOwned<Workspace>(memory_, memory_, workspace_id, launch.cwd, name);
    const auto tab_id = model.next_tab_id;

    workspace->tabs.emplace(memory_, tab_id, std::string_view{});
    model.workspaces.insertProvisional(workspace_id, std::move(workspace));
    ds::Option<std::uint64_t> pane;

    try {
      const TabLocation location{.workspace = {.id = workspace_id}, .tab_id = tab_id};
      const auto* requester = clients.find(client_id);

      pane = panes.launch(model, nullptr, requester != nullptr && requester->bare_prompt, launch, location, size).id;
      model.workspaces.find(workspace_id)->tabs.atMut(0).panes.push(*pane);
      if (replace_view) {
        panes.detachAll(model, clients, client_id);
      }

      panes.attach(model, requireClient(clients, client_id), *pane, size);
    } catch (...) {
      if (pane) {
        panes.remove(model, clients, *pane);
      }

      model.workspaces.erase(workspace_id);
      throw;
    }

    model.workspaces.advanceCounter(workspace_id + 1);
    ++model.next_tab_id;
    ++model.workspace_revision;
    notify(workspace_id, client_id);
    return *pane;
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t WorkspaceService<Poller, History>::nextTabIdentity(const RuntimeModel& model) {
    if (model.next_tab_id == 0) {
      throw RequestError{FailureCode::spawn_failed, "could not start the command"};
    }

    return model.next_tab_id;
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t WorkspaceService<Poller, History>::createAt(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, TabLocation location, Launch launch, TerminalSize size) {
    requireTab(model.workspaces, location);
    auto& client = requireClient(clients, client_id);
    if (!acquireGeometry(model.panes, model.metrics, client, require(model.workspaces, location.workspace))) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }

    LaunchDirectory directory;

    launch = resolveLaunchDirectory(model, client, launch, directory, location);
    if (requireTab(model.workspaces, location).panes.size() == maximum_panes_per_tab) {
      throw RequestError{FailureCode::resource_limit, "Tab pane limit reached"};
    }

    if (launch.cwd.empty()) {
      ownDirectory(launch, directory, require(model.workspaces, location.workspace).path);
    }

    const auto pane = panes.launch(model, &client.colors, client.bare_prompt, launch, location, size).id;

    try {
      panes.attach(model, requireClient(clients, client_id), pane, size);
      requireTab(model.workspaces, location).panes.push(pane);
    } catch (...) {
      panes.remove(model, clients, pane);
      throw;
    }

    ++model.workspace_revision;
    notify(location.workspace.id, client_id);
    return pane;
  }

  template <EventLoop Poller, HistoryEventSink History>
  ds::Option<std::uint64_t> WorkspaceService<Poller, History>::firstPane(const PaneStore& panes, const Workspace& workspace) noexcept {
    return workspace.tabs.empty() ? ds::none : firstPane(panes, workspace.tabs.front());
  }

  template <EventLoop Poller, HistoryEventSink History>
  ds::Option<std::uint64_t> WorkspaceService<Poller, History>::firstPane(const PaneStore& panes, const Tab& tab) noexcept {
    for (const auto identity : tab.panes) {
      if (const auto* pane = panes.find(identity); pane != nullptr && !pane->close_requested && !pane->exit_status) {
        return identity;
      }
    }

    return ds::none;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createDirectories(std::string_view path) {
    if (path.empty() || path.size() >= PATH_MAX || path.front() != '/') {
      throw RequestError{FailureCode::invalid_request, "Working directory must be an absolute path"};
    }

    ds::Array<char, PATH_MAX> directory{};

    std::copy(path.begin(), path.end(), directory.dataMut());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (directory[index] != '/' && directory[index] != '\0') {
        continue;
      }

      const char separator = directory[index];

      directory.atMut(index) = '\0';
      if (::mkdir(directory.data(), 0700) != 0 && sys::lastError() != EEXIST) {
        throw SystemError{"create working directory"};
      }

      directory.atMut(index) = separator;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::sendOpened(ClientSession& client, std::uint64_t request, const Pane& pane, bool created, GenerationField generation) {
    client.connection.send(PaneOpened{
        .request_id = request,
        .pane_id = pane.id,
        .location = pane.location,
        .created = created,
        .pane_generation = generation == GenerationField::included ? pane.generation : 0,
    });
  }

  template class WorkspaceService<NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
  template class WorkspaceService<NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  template <EventLoop Poller, HistoryEventSink History>
  WorktreeService<Poller, History>::WorktreeService(ConcurrentMemory& memory, LimitService& limits)
      : memory_(memory),
        limits_(limits) {}

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::registerEntry(RuntimeModel& model, ClientSession& client, const RegisterWorktree& request) {
    Workspaces::require(model.workspaces, WorkspaceLocation{.id = request.source});
    if (request.created_by) {
      const auto* pane = findPane(model.panes, *request.created_by, client.verified_generation);
      if (pane == nullptr || pane->exit_status || !client.verifiedFor(*pane)) {
        throw RequestError{FailureCode::foreign_process, "Only a process inside the pane may register for it"};
      }
    }

    const auto result = model.worktrees.registerEntry(request);

    ++model.workspace_revision;
    client.connection.send(result);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::launch(RuntimeModel& model, Workspaces& workspaces, Panes& panes, ClientStore& clients, std::uint64_t client_id, const LaunchWorktree& request) {
    const auto& entry = require(model.worktrees, request.worktree);
    auto* found = entry.workspace ? model.workspaces.find(*entry.workspace) : nullptr;
    const bool created = found == nullptr;
    auto workspace = found == nullptr ? std::uint64_t{0} : found->id;

    if (created) {
      workspace = model.workspaces.nextId();
      const auto title = entry.title.view().empty() ? entry.branch.view() : entry.title.view();
      auto owned = makeOwned<Workspace>(memory_, memory_, workspace, entry.path, utf8Prefix(title, 128));

      model.workspaces.insertProvisional(workspace, std::move(owned));
    }

    std::uint64_t pane = 0;

    try {
      auto launch = request.launch;
      LaunchDirectory directory;

      ownDirectory(launch, directory, require(model.worktrees, request.worktree).path);
      launch.cwd_source = 0;
      pane = workspaces.launchBackground(model, panes, Workspaces::ownerColors(model.workspaces, clients, workspace), Workspaces::ownerBarePrompt(model.workspaces, clients, workspace), LaunchTab{request.request_id, workspace, request.label, request.size, launch});
    } catch (...) {
      if (created) {
        model.workspaces.erase(workspace);
      }

      throw;
    }

    model.workspaces.advanceCounter(workspace + 1);
    auto& current = require(model.worktrees, request.worktree);

    current.workspace = workspace;
    current.command_pane = pane;
    current.command_state = CommandState::running;
    current.command_exit = 0;
    const auto program = launchedProgram(request.launch.arguments);

    current.command_label.assign(utf8Prefix(program.substr(program.rfind('/') + 1), 48));
    ++model.workspace_revision;
    const auto& launched = Panes::require(model.panes, pane);

    if (auto* client = clients.find(client_id)) {
      client->connection.send(PaneOpened{request.request_id, launched.id, launched.location, created, launched.generation});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::forget(RuntimeModel& model, Workspaces& workspaces, ClientStore& clients, std::uint64_t client_id, const ForgetWorktree& request) {
    if (const auto workspace = require(model.worktrees, request.worktree).workspace) {
      workspaces.closeWorkspace(model, clients, *workspace);
    }

    model.worktrees.remove(request.worktree);
    ++model.workspace_revision;
    if (auto* client = clients.find(client_id)) {
      client->connection.send(RequestCompleted{.request_id = request.request_id});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  template <typename Background>
  void WorktreeService<Poller, History>::observe(const RuntimeModel& model, Background& background) {
    if (observing_) {
      return;
    }

    const auto now = std::chrono::steady_clock::now();
    const Worktree* selected = nullptr;

    for (const auto* entry : model.worktrees.items()) {
      if (entry == nullptr || entry->state == WorktreeState::gone) {
        continue;
      }

      const auto interval = entry->command_state == CommandState::running && entry->probe_failures < 2 ? std::chrono::seconds{5} : std::chrono::seconds{30};
      if (now - entry->checked_at < interval) {
        continue;
      }

      if (selected == nullptr || selected->checked_at > entry->checked_at) {
        selected = entry;
      }
    }

    if (selected == nullptr) {
      return;
    }

    WorktreeProbeRequest request{};

    request.identity = selected->id;
    request.path.assign(selected->path);
    request.base = selected->base;
    if (background.observeWorktree(request)) {
      observing_ = selected->id;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::observed(RuntimeModel& model, const WorktreeProbeResult& result) {
    if (observing_ != result.identity) {
      return;
    }

    observing_.reset();
    auto* entry = model.worktrees.find(result.identity);
    if (result.timeout != GitProbeTimeout::none && (entry == nullptr || entry->probe_failures == 0)) {
      const auto timeout = result.timeout == GitProbeTimeout::status ? git_status_timeout : git_distance_timeout;
      const auto name = result.timeout == GitProbeTimeout::status ? "gitstatus.status_timeout" : "gitstatus.base_distance_timeout";

      limits_.report(LimitReach{.name = name, .noun = "milliseconds", .value = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(timeout).count())});
    }

    if (entry == nullptr) {
      return;
    }

    entry->checked_at = std::chrono::steady_clock::now();
    bool changed = false;

    if (!result.present) {
      changed = entry->state != WorktreeState::gone;
      entry->state = WorktreeState::gone;
    } else {
      if (!result.branch.view().empty() && result.branch.view() != entry->branch.view()) {
        entry->branch = result.branch;
        changed = true;
      }

      if (entry->base.view().empty() && !result.base.view().empty()) {
        entry->base = result.base;
        changed = true;
      }

      if (result.measured) {
        entry->probe_failures = 0;
        const bool pending = result.dirty || result.files != 0 || result.ahead != 0;

        entry->had_changes |= pending;
        const auto state = !pending && entry->had_changes ? WorktreeState::integrated : WorktreeState::active;

        changed |= entry->state != state || entry->diff_added != result.added || entry->diff_removed != result.removed || entry->diff_files != result.files || entry->commits_ahead != result.ahead;
        entry->state = state;
        entry->diff_added = result.added;
        entry->diff_removed = result.removed;
        entry->diff_files = result.files;
        entry->commits_ahead = result.ahead;
      } else {
        entry->probe_failures = std::min(entry->probe_failures + 1, 2u);
      }
    }

    model.workspace_revision += changed;
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::refresh(RuntimeModel& model) noexcept {
    for (auto* entry : model.worktrees.items()) {
      if (entry == nullptr) {
        continue;
      }

      if (entry->command_pane) {
        const auto* pane = model.panes.find(*entry->command_pane);
        if (pane != nullptr && pane->exit_status) {
          entry->command_exit = *pane->exitCode();
          entry->command_state = CommandState::exited;
          entry->command_pane.reset();
          ++model.workspace_revision;
        }
      }

      if (entry->workspace && model.workspaces.find(*entry->workspace) == nullptr) {
        entry->workspace.reset();
        ++model.workspace_revision;
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  Worktree& WorktreeService<Poller, History>::require(Worktrees& worktrees, std::uint64_t identity) {
    auto* entry = worktrees.find(identity);
    if (entry == nullptr) {
      throw RequestError{FailureCode::worktree_not_found, "worktree not found"};
    }

    return *entry;
  }

  template class WorktreeService<NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;
  template class WorktreeService<NativeEventLoop<ConcurrentMemory>, DiscardedHistory>;

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  Runtime<Poller, Background>::Runtime(ConcurrentMemory& memory, Poller& poller, Background& background, const RuntimeOptions& options, ProxyClientConfiguration proxy)
      : memory_(memory),
        poller_(poller),
        background_(background),
        proxy_(proxy),
        listener_(options.socket),
        model_(memory, options.graphics),
        clients_(memory),
        admissions_(poller_, limits_),
        client_layouts_(memory),
        panes_(memory, poller_, limits_, PaneLaunchOptions{options.socket, proxy, options.control_policy, options.shell_integration, options.ssh_integration}, background),
        workspaces_(memory),
        worktrees_(memory, limits_),
        executions_(memory, poller_, limits_),
        process_inspector_(*options.manifests),
        agents_(memory),
        process_probe_(process_inspector_),
        observations_(limits_, *options.manifests, process_probe_, background_),
        media_(poller_, limits_),
        descents_(process_inspector_),
        session_(memory),
        metrics_(Clock::now()),
        workspace_git_(limits_, memory),
        words_(memory, options.configuration_directory),
        agent_files_(memory),
        descriptions_(memory, background_, options.descriptions),
        telemetry_(options.socket, proxy.status()) {
    model_.cli_executable = options.cli_executable;
    model_.capture_output = options.capture_output;
    model_.manifests = *options.manifests;
    agents_.enableDescriptions(descriptions_.enabled());
    if (options.fresh && !options.session.path.empty()) {
      checkpoint::FileStore<ConcurrentMemory>::setAside(memory, options.session.path);
    }

    session_.configure(model_, panes_, client_layouts_, options.session);
    poller_.watch(listener_.descriptor(), eventToken(EventSource::listener, 0));
    for (const int descriptor : background_.descriptors()) {
      poller_.watch(descriptor, eventToken(EventSource::worker, 0));
    }

    if (session_.descriptor() >= 0) {
      poller_.watch(session_.descriptor(), eventToken(EventSource::worker, 0));
    }

    poller_.watch(observations_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(media_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(descents_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(metrics_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(runtime_clipboard_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(workspace_git_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(shell_git_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(words_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(worktree_detection_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(agent_files_.descriptor(), eventToken(EventSource::worker, 0));
    if (descriptions_.descriptor() >= 0) {
      poller_.watch(descriptions_.descriptor(), eventToken(EventSource::worker, 0));
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::run() {
    IgnoreCaptureEvents captures;

    run(captures);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  bool Runtime<Poller, Background>::route(const Event& event) {
    if (event.kind == EventKind::signal) {
      if (event.descriptor == SIGCHLD) {
        children_exited_ = true;
        return true;
      }

      model_.stopping = true;
      return false;
    }

    switch (eventSource(event.token)) {
    case EventSource::listener:
      accept();
      break;
    case EventSource::client:
      clientEvent(event);
      break;
    case EventSource::handshake:
      admissions_.event(event, [this](FileDescriptor descriptor) {
        admitClient(std::move(descriptor));
      });

      break;
    case EventSource::pane:
      paneEvent(event);
      break;
    case EventSource::execution_output:
    case EventSource::execution_error:
    case EventSource::execution_input:
      executions_.event(event);
      break;
    case EventSource::worker:
      collectBackground();
      break;
    }

    return true;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::accept() {
    constexpr unsigned accept_batch = 16;

    for (unsigned index = 0; index < accept_batch; ++index) {
      auto descriptor = listener_.accept();
      if (!descriptor) {
        return;
      }

      try {
        admissions_.begin(clients_.size(), std::move(descriptor));
      } catch (const std::exception&) {
        return;
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::admitClient(FileDescriptor descriptor) {
    const auto identity = clients_.nextId();
    auto client = makeOwned<ClientSession>(memory_, memory_, identity, std::move(descriptor));

    client->connection.negotiated = true;
    client->peer_identity = process_inspector_.peer(client->connection.descriptor());
    const auto handle = clients_.insert(identity, std::move(client));
    auto& admitted = requireClient(clients_, identity);

    admitted.event_identity = handle;
    try {
      if (handle > maximum_event_identity) {
        throw std::bad_alloc{};
      }

      poller_.watch(admitted.connection.descriptor(), eventToken(EventSource::client, handle));
    } catch (...) {
      dropClient(identity);
      throw;
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::dropClient(std::uint64_t identity) noexcept {
    auto* client = clients_.find(identity);
    if (client == nullptr) {
      return;
    }

    try {
      executions_.disconnect(identity);
    } catch (...) {
    }

    background_.cancel(identity);
    deferred_reports_.cancel(*client);
    client->connection.closing = true;
    const int descriptor = client->connection.descriptor();

    panes_.detachAll(model_, clients_, identity);
    workspaces_.releaseHeldTabs(model_, panes_, clients_, identity);
    releaseAllGeometry(model_.workspaces, clients_, identity);
    Control::abandon(clients_, identity);
    poller_.remove(descriptor);
    clients_.erase(identity);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::deliverQueued() noexcept {
    limits_.deliver(model_, clients_);
    agents_.deliverSounds(clients_);
    workspaces_.deliverNotices(clients_);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::clientEvent(const Event& event) {
    auto* client = clients_.findHandle(eventIdentity(event.token));
    if (client == nullptr || client->connection.descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_client_messages));
      return;
    }

    const auto identity = client->id;

    try {
      if (event.kind == EventKind::readable) {
        if (client->connection.read_paused) {
          return;
        }

        if (!client->connection.read()) {
          dropClient(identity);
          return;
        }

        receive(identity);
      } else {
        writeClient(identity, Clock::now());
      }

      if (auto* current = clients_.find(identity)) {
        updateWriteInterest(poller_, *current);
      }
    } catch (const std::exception&) {
      dropClient(identity);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::paneEvent(const Event& event) {
    TELAR_TRACE("runtime.paneEvent");
    auto* pane = model_.panes.findHandle(eventIdentity(event.token));
    if (pane == nullptr || pane->process->descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    const auto identity = pane->id;

    try {
      if (event.kind == EventKind::readable) {
        const auto mode = model_.panes.size() == 1 ? Pane::ReadMode::burst : Pane::ReadMode::once;
        if (!pane->read(mode)) {
          poller_.remove(pane->process->descriptor());
        }
      }

      panes_.flushInput(*pane);
      observations_.observe(model_, agents_, identity);
      if (auto* observed = model_.panes.find(identity)) {
        media_.updateReadInterest(*observed);
      }
    } catch (const std::exception&) {
      if (auto* failed = model_.panes.find(identity)) {
        panes_.failOutput(*failed);
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::receive(std::uint64_t identity) {
    Frames frames{memory_};

    requireClient(clients_, identity).connection.exchange(frames);
    bool remaining = false;

    try {
      remaining = Connection<ConcurrentMemory>::dispatch(
          frames,
          [&] {
            const auto* client = clients_.find(identity);

            return client != nullptr && !client->connection.read_paused;
          },
          [&](std::span<const Byte> payload, DecodeStorage& storage) {
            if (!requireClient(clients_, identity).connection.closing) {
              dispatch(identity, payload, storage);
            }
          }
      );
    } catch (...) {
      if (auto* client = clients_.find(identity)) {
        client->connection.exchange(frames);
      }

      throw;
    }

    if (auto* client = clients_.find(identity)) {
      client->connection.exchange(frames);
      client->connection.buffered_requests = remaining;
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  template <typename Message>
  void Runtime<Poller, Background>::request(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage& storage) {
    const auto message = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{model_.metrics.decode});
      return Codec::decode<Message>(payload, storage);
    }();

    auto& client = requireClient(clients_, identity);
    if (client.role == ClientRole::undecided) {
      if constexpr (std::same_as<Message, RequestRuntimeState>) {
        client.role = message.interactive ? ClientRole::interactive : ClientRole::control;
      } else {
        client.role = classifyRequest(static_cast<ClientTag>(payload.front()));
      }
    }

    std::uint64_t request_id = 0;

    if constexpr (requires { message.request_id; }) {
      request_id = message.request_id;
    }

    try {
      if (const auto reporter = reporterOf(model_.manifests, message)) {
        const auto decision = deferred_reports_.evaluate(model_.panes, agents_, requireClient(clients_, identity), *reporter, payload);
        if (decision == ReportDecision::rejected) {
          requireClient(clients_, identity).connection.send(RequestFailed{.request_id = request_id, .code = FailureCode::foreign_process, .message = "The report belongs to another agent"});
          return;
        }

        if (decision == ReportDecision::deferred) {
          try {
            observations_.observe(model_, agents_, reporter->pane);
          } catch (...) {
            auto& deferred = requireClient(clients_, identity);

            deferred_reports_.cancel(deferred);
            deferred.deferred_report.payload.clear();
            throw;
          }

          return;
        }
      }

      handle(identity, message);
    } catch (const RequestError& error) {
      if (error.code() == FailureCode::resource_limit) {
        limits_.report(LimitReach{.name = "runtime.request_capacity", .route = "request"});
      }

      fail(identity, RequestFailed{.request_id = request_id, .code = error.code(), .message = error.what()});
    } catch (const JsonError& error) {
      fail(identity, RequestFailed{.request_id = request_id, .code = FailureCode::invalid_request, .message = error.what()});
    } catch (const SystemError& error) {
      fail(identity, RequestFailed{.request_id = request_id, .code = FailureCode::spawn_failed, .message = error.what()});
    } catch (const std::bad_alloc&) {
      limits_.report(LimitReach{.name = "runtime.memory", .route = "request"});
      fail(identity, RequestFailed{.request_id = request_id, .code = FailureCode::resource_limit, .message = "Runtime memory or capacity limit reached"});
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::fail(std::uint64_t identity, const RequestFailed& failure) {
    if (auto* client = clients_.find(identity)) {
      client->connection.send(failure);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::dispatch(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage& storage) {
    TELAR_TRACE("runtime.dispatch");
    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_messages));
    const bool recognized = dispatchRequest(static_cast<ClientTag>(payload.front()), [&]<typename Message> {
      request<Message>(identity, payload, storage);
    });

    if (!recognized) {
      throw EncodingError{"Unknown request tag"};
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportLimit& message) {
    limits_.receive(model_.limits, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryLimits& message) {
    LimitService::query(requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const LaunchTab& message) {
    workspaces_.launchTab(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RegisterWorktree& message) {
    Worktrees::registerEntry(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const LaunchWorktree& message) {
    worktrees_.launch(model_, workspaces_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ForgetWorktree& message) {
    Worktrees::forget(model_, workspaces_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ExecutionRequest& message) {
    executions_.request(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const VerifyPaneDescent& message) {
    Descents::verify(model_.panes, requireClient(clients_, identity), message);
    descents_.schedule(clients_);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportAgent& message) {
    agents_.report(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportAgentTitle& message) {
    agents_.reportTitle(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportAgentSession& message) {
    agents_.reportSession(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportAgentProgress& message) {
    if (!agents_.reportProgress(model_, requireClient(clients_, identity), message)) {
      limits_.report(LimitReach{.name = "agents.max_tasks", .noun = "tasks", .value = AgentProgress::task_capacity, .requested = AgentProgress::task_capacity + 1, .route = "agents"});
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const InterruptAgent& message) {
    const bool focused = Agents::focused(clients_, client_layouts_, message.pane_id);

    agents_.interrupt(model_, panes_, requireClient(clients_, identity), message, focused);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t, const AcknowledgeAgent& message) {
    agents_.acknowledge(message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryAgents&) {
    requireClient(clients_, identity).agent_snapshot_requested = true;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReportAgentCommand& message) {
    auto& client = requireClient(clients_, identity);
    const auto& pane = agents_.validateCommand(model_, client, message);
    const auto location = pane.location;
    const auto history_session = pane.history_session;
    const auto* workspace = model_.workspaces.find(location.workspace.id);

    background_.submit(client.id, message, RequestContext{.location = location, .history_session = history_session, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .received_at_ms = client.deferred_report.reportTime().milliseconds});
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CompleteWords& message) {
    auto& client = requireClient(clients_, identity);
    const auto* pane = model_.panes.find(message.pane_id);
    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Could not complete words"};
    }

    // A remote shell's commands, branches and hosts are not this host's to read.
    if (pane->shell_state.remote) {
      client.connection.send(CompletionWords{.request_id = message.request_id, .truncated = true, .words = {}});
      return;
    }

    auto request = makeWordRequest(client, message.request_id, message.provider, message.prefix, *pane);

    request.directory.assign(pane->shell_zones && !pane->shell_zones->directory().empty() ? pane->shell_zones->directory() : std::string_view{pane->cwd});
    request.home.assign(processHome());
    words_.request(request);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestCommandSpec& message) {
    auto& client = requireClient(clients_, identity);
    const auto* pane = model_.panes.find(message.pane_id);
    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Could not find a command spec"};
    }

    if (pane->shell_state.remote) {
      client.connection.send(CommandSpec{.request_id = message.request_id, .command = message.command, .state = CommandSpecState::unavailable, .digest = 0, .source = {}});
      return;
    }

    auto request = makeWordRequest(client, message.request_id, CompletionProvider::command, message.command, *pane);

    request.spec = true;
    request.known_digest = message.known_digest;
    words_.request(request);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  WordRequest Runtime<Poller, Background>::makeWordRequest(const ClientSession& client, std::uint64_t request_id, CompletionProvider provider, std::string_view prefix, const Pane& pane) const {
    WordRequest request{.client = client.id, .request = request_id, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.prefix.assign(prefix);
    request.path.assign(pane.shell_zones && !pane.shell_zones->path().empty() ? pane.shell_zones->path() : runtime_path_);
    request.shell = pane.shell_state.shell;
    if (pane.shell_zones) {
      request.names = pane.shell_zones->names();
    }

    return request;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const FindPaths& message) {
    auto& client = requireClient(clients_, identity);
    if (!background_.tryPaths(client.id, message, client.connection)) {
      submitBackground(background_, client, message);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const OpenEditor& message) {
    // Generation 0 names whatever generation the pane has, as an editor asked from a client
    // that predates generations does.
    const auto* source = message.pane_generation == 0 ? model_.panes.find(message.pane_id) : findPane(model_.panes, message.pane_id, message.pane_generation);
    if (source == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "Could not request editor reuse"};
    }

    if (source->exit_status || source->close_requested) {
      throw RequestError{FailureCode::pane_exited, "Could not request editor reuse"};
    }

    if (background_.editorBusy()) {
      throw RequestError{FailureCode::resource_limit, "Could not request editor reuse"};
    }

    RequestContext context;
    const auto editor = identifyEditor(message.editor);
    if (editor != EditorKind::unsupported) {
      for (const auto* pane : model_.panes.items()) {
        if (pane == nullptr || pane->exit_status || pane->close_requested || pane->location.workspace.id != source->location.workspace.id || pane->location.tab_id != source->location.tab_id || identifyEditor(pane->process_cache.identified.name.view()) != editor) {
          continue;
        }

        const auto group = ::tcgetpgrp(pane->process->descriptor());
        const auto process = group > 0 ? process_inspector_.identity(group) : ds::none;
        if (process && context.editor_candidate_count < context.editor_candidates.size()) {
          context.editor_candidates.atMut(context.editor_candidate_count++) = {pane->id, pane->generation, *process};
        }
      }
    }

    auto& client = requireClient(clients_, identity);

    submitBackground(background_, client, message, context);
    client.editor_source = source->id;
    client.editor_generation = source->generation;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SuggestCommand& message) {
    auto& client = requireClient(clients_, identity);

    if (!background_.suggestionsAvailable()) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::unavailable});
      return;
    }

    auto* pane = model_.panes.find(message.pane_id);
    if (pane == nullptr) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
      return;
    }

    try {
      TextReader reader{memory_, pane->terminal, 4096};

      reader.read(PaneTextSource::screen, 24);
      const auto prompt = suggestionPrompt(memory_, pane->cwd, reader.text(), message.text);

      submitBackground(background_, client, message, RequestContext{.prompt = prompt});
    } catch (const RequestError&) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    } catch (const std::bad_alloc&) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const OpenPane& message) {
    workspaces_.open(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CreatePane& message) {
    workspaces_.createPane(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ClosePane& message) {
    Workspaces::closePane(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CreateWorkspace& message) {
    workspaces_.createWorkspace(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RenameWorkspace& message) {
    workspaces_.renameWorkspace(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CreateTab& message) {
    workspaces_.createTab(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RenameTab& message) {
    workspaces_.renameTab(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CloseTab& message) {
    workspaces_.closeTab(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const HoldTab& message) {
    workspaces_.holdTab(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const MoveTab& message) {
    workspaces_.moveTab(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestTabSnapshot& message) {
    Workspaces::tabSnapshot(model_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestWorkspaceSnapshot& message) {
    Workspaces::workspaceSnapshot(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const PaneInput& message) {
    panes_.input(model_, clients_, identity, message, [&agents = agents_](const Pane& pane, std::span<const Byte> bytes) {
      agents.observeInput(pane, bytes);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const PaneCommand& message) {
    panes_.command(model_, clients_, identity, message, [&agents = agents_](const Pane& pane, std::span<const Byte> bytes) {
      agents.observeInput(pane, bytes);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigureShellPrompt& message) {
    requireClient(clients_, identity).bare_prompt = message.bare;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const PaneResize& message) {
    panes_.resize(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadRuntimeClipboard& message) {
    runtime_clipboard_.read(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CompleteClipboardDesktop& message) {
    if (auto* pane = ClipboardService::complete(model_.panes, requireClient(clients_, identity), message)) {
      panes_.flushInput(*pane);
      media_.updateReadInterest(*pane);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const PastePaneClipboard& message) {
    panes_.pasteClipboard(model_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigurePaneDesktop& message) {
    panes_.configureDesktop(model_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigureTerminalColors& message) {
    panes_.configureColors(model_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SearchPane& message) {
    Panes::search(model_.panes, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SearchPaneRows& message) {
    Panes::search(model_.panes, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadPaneRows& message) {
    Panes::readRows(model_.panes, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CopySelection& message) {
    panes_.copySelection(model_.panes, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadPane& message) {
    Panes::readText(requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SendPaneText& message) {
    const bool focused = Agents::focused(clients_, client_layouts_, message.pane_id);

    agents_.sendText(model_, panes_, requireClient(clients_, identity), message, focused);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const DetachPane& message) {
    panes_.detach(model_, clients_, identity, message.pane_id);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const FrameAck& message) {
    if (auto* attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->frames.acknowledge(message.frame_id);
      TELAR_DIAGNOSTIC(model_.metrics.frames.merge(attachment->frames.takeCounters()));
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestSnapshot& message) {
    if (auto* attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->frames.requestSnapshot();
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SetPaneViewport& message) {
    if (auto* attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      // At or past the bottom the view follows the output, as before any scroll; a row
      // above it stays put while output grows.
      std::uint32_t bottom = 0;

      if (const auto* pane = model_.panes.find(message.pane_id)) {
        const auto& screen = pane->terminal.screen;

        bottom = screen.scroll.total_rows - std::min<std::uint32_t>(screen.scroll.total_rows, screen.rows);
      }

      attachment->viewport = message.offset >= bottom ? ds::none : ds::Option{message.offset};
      attachment->frames.requestSnapshot();
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigureFrameInterval& message) {
    requireClient(clients_, identity).frame_interval = std::chrono::nanoseconds{message.interval_ns};
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestRuntimeState& message) {
    auto& client = requireClient(clients_, identity);
    if (client.identity != 0 && client.identity != message.client_identity) {
      throw EncodingError{"Subscribed client identity cannot change"};
    }

    if (client.subscribed) {
      return;
    }

    client.identity = message.client_identity;
    client.subscribed = true;
    client.workspace_revision = 0;
    client.agent_snapshot_requested = true;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryClients& message) {
    Control::list(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const DetachClient& message) {
    Control::detach(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestClientCommand& message) {
    Control::requestCommand(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CompleteClientCommand& message) {
    Control::completeCommand(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestPaneFocus& message) {
    Control::requestFocus(model_.panes, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CompletePaneFocus& message) {
    Control::completeFocus(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ShowNotification& message) {
    Control::notify(clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const UpdateClientLayout& message) {
    client_layouts_.retain(model_, requireClient(clients_, identity).identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryHistory& message) {
    auto& client = requireClient(clients_, identity);

    submitBackground(background_, client, message, RequestContext{.persistent_client = client.role == ClientRole::interactive});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ImportHistory& message) {
    auto& client = requireClient(clients_, identity);

    submitBackground(background_, client, message);
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const DeleteHistory& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const PruneHistory& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadHistoryOutput& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const HistoryStatsQuery& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigureGraphics& message) {
    auto& client = requireClient(clients_, identity);

    client.shared_graphics = message.shared;
    for (auto& attachment : client.attachments) {
      attachment->graphics.configure(message.shared);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const GraphicsCredit& message) {
    if (auto* attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->graphics.returnCredit(message.bytes);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestGraphicsSnapshot& message) {
    if (auto* attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->graphics.requestSnapshot();
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t, const RuntimeStop&) {
    model_.stopping = true;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  template <typename Message>
  void Runtime<Poller, Background>::submitBackground(Background& background, const ClientSession& client, const Message& message, RequestContext context) {
    if constexpr (std::same_as<Message, OpenEditor>) {
      if (client.editor_source != 0) {
        throw RequestError{FailureCode::resource_limit, "An editor request is already pending"};
      }
    }

    background.submit(client.id, message, context);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  bool Runtime<Poller, Background>::isHistoryRequest(ClientTag tag) noexcept {
    return ClientRequests::lane(tag) == RequestLane::history;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::collectBackground() {
    TELAR_TRACE("runtime.collectBackground");
    session_.collect();
    observations_.collect(model_, agents_);
    media_.collect(model_, clients_, panes_);
    descents_.collect(clients_, model_.panes);
    answerDeferredReports();
    metrics_.collect();
    runtime_clipboard_.collect(clients_);
    workspace_git_.collect(model_, Clock::now());
    shell_git_.collect([&](const ShellGitResult& result) {
      auto* pane = findPane(model_.panes, result.pane, result.generation);
      if (pane != nullptr && !pane->shell_state.remote && !(pane->git == result.summary)) {
        pane->git = result.summary;
        ++pane->git_revision;
      }
    });

    words_.collect([&](const WordResult& result) {
      deliverWords(result);
    });

    worktree_detection_.collect(model_);
    agent_files_.collect(agents_);
    descriptions_.collect(agents_);
    if (const auto failures = background_.takeHistoryFailures()) {
      limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed events", .requested = failures, .route = "history"});
    }

    background_.collectWorktrees([&](const WorktreeProbeResult& result) {
      worktrees_.observed(model_, result);
    });

    background_.collect([&](std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) {
      deliverBackgroundReply(client_id, request_tag, payload);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::deliverWords(const WordResult& result) {
    auto* client = clients_.find(result.client);
    if (client == nullptr) {
      return;
    }

    if (result.spec) {
      client->connection.send(CommandSpec{.request_id = result.request, .command = result.command, .state = result.spec_state, .digest = result.digest, .source = result.source, .expansion = result.expansion});
      return;
    }

    ds::Vec<CompletionWord, ConcurrentMemory> words{memory_};

    words.reserve(result.words.size());
    for (const auto& word : result.words) {
      words.push({word.text.view(), word.description.view()});
    }

    client->connection.send(CompletionWords{.request_id = result.request, .truncated = result.truncated, .words = words.view()});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::deliverBackgroundReply(std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) {
    if (request_tag == ClientTag::import_history) {
      return;
    }

    if (request_tag == ClientTag::report_agent_command) {
      if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
        limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed commands", .route = "history"});
      }

      return;
    }

    auto* client = clients_.find(client_id);
    if (client == nullptr || client->connection.closing) {
      return;
    }

    try {
      if (payload.front() == static_cast<Byte>(ServerTag::editor_opened)) {
        deliverEditorReply(model_.panes, *client, payload);
      } else {
        const auto tag = static_cast<ServerTag>(payload.front());
        if (tag == ServerTag::history_results || tag == ServerTag::history_output || tag == ServerTag::history_stats_result || tag == ServerTag::command_suggestion) {
          client->connection.trySendPayload(payload);
        } else {
          client->connection.sendPayload(payload);
        }

        if (client->role == ClientRole::control && isHistoryRequest(request_tag)) {
          client->connection.closing = true;
        }

        if (request_tag == ClientTag::open_editor) {
          client->editor_source = 0;
        }
      }

      updateWriteInterest(poller_, *client);
    } catch (...) {
      dropClient(client_id);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::deliverEditorReply(const PaneStore& panes, ClientSession& client, std::span<const Byte> payload) {
    ds::Array<Byte, 256> scratch;
    DecodeStorage storage{scratch.viewMut()};
    auto reply = Codec::decode<EditorOpened>(payload, storage);
    const auto* source = livePane(panes, client.editor_source, client.editor_generation);
    const auto* target = livePane(panes, reply.pane_id, reply.pane_generation);
    if (source == nullptr ||
        (reply.outcome == EditorOutcome::opened && (target == nullptr || target->location.workspace.id != source->location.workspace.id || target->location.tab_id != source->location.tab_id))) {
      reply.outcome = EditorOutcome::failed;
    }

    client.editor_source = 0;
    client.connection.send(reply);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::chrono::nanoseconds Runtime<Poller, Background>::publish(Clock::time_point now) {
    TELAR_TRACE("runtime.publish");
    admissions_.expire(now);
    runtime_clipboard_.expire(clients_, now);
    media_.collect(model_, clients_, panes_);
    std::chrono::nanoseconds timeout = std::chrono::milliseconds{100};
    // Panes are polled for what changes without a sound on a beat, not on every wake: output
    // from any pane wakes the loop, and asking each of them would cost syscalls per pane.
    const bool poll_panes = now >= next_pane_poll_;
    if (poll_panes) {
      next_pane_poll_ = now + pane_poll_interval;
    }

    timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(next_pane_poll_ - now));
    const bool reap = std::exchange(children_exited_, false) || poll_panes;

    for (auto* pane : model_.panes.items()) {
      if (pane != nullptr) {
        try {
          if (ClipboardService::advance(clients_, *pane, now) && !pane->output_closed) {
            panes_.flushInput(*pane);
            media_.updateReadInterest(*pane);
          }
        } catch (const std::exception&) {
          panes_.failOutput(*pane);
        }
      }

      // SIGCHLD says a child exited; a closed output usually means it did. The beat catches a
      // child whose signal went to no one, such as one reaped while a test drives the loop.
      if (pane != nullptr && !pane->exit_status && (reap || pane->output_closed)) {
        pane->exit_status = pane->process.getMut().reap();
        model_.pane_revision += pane->exit_status.hasValue();
      }

      // A program can change the terminal without printing, as `read -s` does; one that
      // prints is observed as it reads.
      if (pane != nullptr && poll_panes && !pane->exit_status && pane->shell_state.phase != ShellPhase::prompt) {
        pane->observeShell();
      }

      // A remote shell's repository is not on this host: forget the local one it left.
      if (pane != nullptr && pane->shell_state.remote && (pane->git.repository || !pane->git_directory.view().empty())) {
        pane->git = {};
        pane->git_directory.assign(std::string_view{});
        ++pane->git_revision;
      }

      // Back at the prompt after a command, or in another directory: read its repository.
      if (pane != nullptr && pane->shell_zones && !pane->shell_state.remote && pane->shell_state.phase == ShellPhase::prompt) {
        const auto directory = pane->shell_zones->directory();
        if (pane->git_commands != pane->shell_state.commands || pane->git_directory.view() != directory) {
          pane->git_commands = pane->shell_state.commands;
          pane->git_directory.assign(directory);
          shell_git_.request(pane->id, pane->generation, directory);
        }
      }

      if (pane != nullptr && pane->exit_status && pane->output_closed && !pane->exit_observed) {
        pane->observer->shellExit(*pane->exitCode());
        pane->exit_observed = true;
      }
    }

    if (executions_.refresh(model_)) {
      timeout = std::min(timeout, std::chrono::nanoseconds{std::chrono::milliseconds{10}});
    }

    try {
      observations_.refresh(model_, agents_);
      answerDeferredReports();
      agents_.refresh(model_, panes_, clients_, client_layouts_);
      agent_files_.tick(agents_, now);
      descriptions_.tick(agents_);
      worktree_detection_.tick(model_);
    } catch (const std::bad_alloc&) {
    } catch (const RequestError&) {
    }

    Worktrees::refresh(model_);
    worktrees_.observe(model_, background_);
    workspaces_.collectExited(model_, panes_, clients_);
    timeout = std::min(timeout, session_.tick(model_, client_layouts_, agents_, now));
    timeout = std::min(timeout, metrics_.tick(now));
    timeout = std::min(timeout, workspace_git_.tick(model_, now));
    deliverQueued();

    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {
      const auto* listed = clients_.items()[slot];
      if (listed == nullptr) {
        continue;
      }

      const auto identity = listed->id;

      if (listed->connection.closing && !listed->connection.hasOutput()) {
        dropClient(identity);
        continue;
      }

      try {
        if (listed->connection.closing) {
          auto& closing = requireClient(clients_, identity);

          closing.connection.write(ResponseProjection{memory_, model_});
          updateWriteInterest(poller_, closing);
          continue;
        }

        if (listed->connection.buffered_requests && !listed->connection.read_paused) {
          receive(identity);
          timeout = std::chrono::nanoseconds::zero();
        }

        if (Panes::advanceSearch(model_.panes, requireClient(clients_, identity))) {
          timeout = std::chrono::nanoseconds::zero();
        }

        timeout = std::min(timeout, writeClient(identity, now));
        updateWriteInterest(poller_, requireClient(clients_, identity));
      } catch (const std::exception&) {
        dropClient(identity);
      }
    }

    media_.start(model_, clients_, panes_);
    return timeout;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::chrono::nanoseconds Runtime<Poller, Background>::writeClient(std::uint64_t identity, Clock::time_point now) {
    StateProjection state{workspaces_, agents_, metrics_, client_layouts_, proxy_};
    const auto result = ClientDelivery{memory_, model_}.write(requireClient(clients_, identity), state, now);
    if (result.detach_pane) {
      panes_.release(model_, clients_, identity, *result.detach_pane);
    }

    return result.timeout;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::updateWriteInterest(Poller& poller, ClientSession& client) {
    const bool enabled = client.connection.hasOutput();
    if (enabled != client.connection.write_interest) {
      poller.writeInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), enabled);
      client.connection.write_interest = enabled;
    }

    const bool readable = !client.connection.read_paused;
    if (readable != client.connection.read_interest) {
      poller.readInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), readable);
      client.connection.read_interest = readable;
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::answerDeferredReports() {
    const auto due = deferred_reports_.due(clients_, model_.panes, agents_, ObservationTime::now());

    for (const auto identity : due.ids()) {
      auto* client = clients_.find(identity);
      if (client == nullptr) {
        continue;
      }

      ds::Vec<Byte, ConcurrentMemory> payload{memory_};

      deferred_reports_.open(*client, payload);
      Frames frames{memory_};

      client->connection.exchange(frames);
      bool answered = false;

      try {
        if (!client->connection.closing) {
          DecodeStorage storage{frames.decode.viewMut()};

          dispatch(identity, std::span<const Byte>{payload}, storage);
          answered = true;
        }
      } catch (...) {
        if (auto* failed = clients_.find(identity)) {
          failed->connection.closeImmediately();
        }
      }

      if (auto* current = clients_.find(identity)) {
        current->connection.exchange(frames);
        DeferredReports<Agents>::close(*current, payload);
        if (answered) {
          updateWriteInterest(poller_, *current);
        }
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::stop() noexcept {
    admissions_.clear();
    session_.finish(model_, client_layouts_, agents_);
    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {
      auto* client = clients_.items()[slot];
      if (client == nullptr) {
        continue;
      }

      const auto identity = client->id;

      try {
        client->connection.send(RuntimeStopping{});
        client->connection.write(ResponseProjection{memory_, model_});
      } catch (...) {
      }

      dropClient(identity);
    }

    for (auto* pane : model_.panes.items()) {
      if (pane != nullptr) {
        pane->process->signal(SIGTERM);
        pane->observer->finishSession();
      }
    }

    observations_.finish(model_);
    media_.finish(model_);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::string_view Runtime<Poller, Background>::runtimePath() {
    const char* path = std::getenv("PATH");

    return path == nullptr ? std::string_view{"/usr/bin:/bin"} : std::string_view{path};
  }

  template class Runtime<NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;

}
