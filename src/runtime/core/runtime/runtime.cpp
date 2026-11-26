module;
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.core.runtime;

import telar.runtime.files.touches;
import telar.runtime.nvim.editor;
import telar.runtime.nvim.provision;
import telar.runtime.paths.query_task;
import telar.ghostty.vt;
import telar.sys.process;
import telar.platform.process;
import telar.platform.error;
import telar.platform.paths;
import telar.plugins;
import telar.runtime.workspaces.git_status;
import telar.runtime.terminal.text_reader;
import telar.base.editors;
import telar.base.text.utf8;
import telar.runtime.host.launch_program;
import telar.runtime.suggestions.engine;
import telar.runtime.diagnostics.line;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // What an agent's line starts with when it names the tool it runs.
    constexpr std::string_view agent_tool_mark = "» ";

    std::uint64_t secondsNow() noexcept {
      return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
    }

    // The socket to listen on, once a fresh start has set the previous session aside: the listener
    // makes the runtime reachable, so a client that finds the socket finds the session set aside.
    tbc::val_a<std::string_view> setAsideBeforeListening(ConcurrentMemory& memory, tbc::ref_a<RuntimeOptions> options) {
      if (options.fresh && !options.session.path.empty()) {
        checkpoint::FileStore<ConcurrentMemory>::setAside(memory, options.session.path);
      }

      return options.socket;
    }

    // The bytes a key's encoding takes at most.
    constexpr std::size_t encoded_key_bytes = 128;

    constexpr std::int64_t milliseconds_per_second = 1000;

    // Applies a measured probe of a worktree's checkout; whether what clients show of it changed.
    bool applyMeasurement(Worktree& entry, const WorktreeProbeResult& result) noexcept {
      entry.probe_failures = 0;
      const bool pending = result.dirty || result.files != 0 || result.ahead != 0;

      entry.had_changes |= pending;
      const auto state = !pending && entry.had_changes ? WorktreeState::integrated : WorktreeState::active;
      const bool changed = entry.state != state || entry.diff_added != result.added || entry.diff_removed != result.removed || entry.diff_files != result.files || entry.commits_ahead != result.ahead;

      entry.state = state;
      entry.diff_added = result.added;
      entry.diff_removed = result.removed;
      entry.diff_files = result.files;
      entry.commits_ahead = result.ahead;
      return changed;
    }

  }

  void AgentSnapshotBuilder::publish(ClientSession& client, const RuntimeModel& model, const AgentRegistry<ConcurrentMemory>& registry) {
    // The entries view the model, the registry and these texts only while the snapshot is sent.
    ds::Array<AgentSnapshotEntry, AgentRegistry<ConcurrentMemory>::capacity> entries;
    auto& directories = directories_;
    auto& placeholders = placeholders_;
    // Which entries show their manifest's placeholder: the texts are lent once every one is written,
    // as Rust lends no element of an array it still indexes mutably.
    ds::Array<bool, AgentRegistry<ConcurrentMemory>::capacity> placeholder_titles{};
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

      const auto* const position = std::ranges::find(tab->panes, pane->id);
      if (position == tab->panes.end()) {
        continue;
      }

      auto provider = describeProvider(agent->provider);
      std::string_view icon;
      const auto* manifest = model.manifests.find(agent->provider);
      if (manifest != nullptr) {
        FixedText<title_bytes> generated;

        placeholders.atMut(count).assign(manifest->placeholderTitle(generated));
        provider = {.name = manifest->name.view(), .display_name = manifest->displayName(), .attachments = manifest->attachments};
        icon = manifest->icon.view();
      }

      labelDirectory(directories.atMut(count), pane->cwd);

      const bool terminal_title = agent->title_source == AgentTitleSource::telar && !programTitle(*pane).text.empty();
      const bool placeholder_title = !terminal_title && agent->title.view().empty();
      auto session_title = placeholder_title ? provider.placeholder : agent->title.view();
      auto title_source = agent->title_source;

      if (terminal_title) {
        session_title = utf8Prefix(programTitle(*pane).text, title_bytes);
        title_source = AgentTitleSource::terminal;
      }

      placeholder_titles.atMut(count) = placeholder_title && manifest != nullptr;
      entries.atMut(count) = {
          .pane_id = pane->id,
          .pane_generation = pane->generation,
          .location = pane->location,
          .pane_index = static_cast<std::uint16_t>(position - tab->panes.begin() + 1),
          .process_id = static_cast<std::uint32_t>(agent->process_identity ? agent->process_identity->pid : pane->process_id),
          .session_id = agent->session_id,
          .workspace_label = utf8Prefix(workspace->displayName(), label_bytes),
          .tab_label = tab->label,
          .session_title = session_title,
          .title_source = title_source,
          .title_state = agent->title_state,
          .provider = agent->provider,
          .provider_name = provider.name,
          .display_name = provider.display_name,
          .icon = icon,
          .attachments = provider.attachments,
          .status = agent->status,
          .blocked_reason = agent->blocked_reason,
          .last_event = agent->event.view(),
          .status_age_s = static_cast<std::uint32_t>(std::clamp<std::int64_t>((now - agent->changed_at) / milliseconds_per_second, 0, std::numeric_limits<std::uint32_t>::max())),
          .source = agent->source,
          .authority = agent->authority,
          .confidence = agent->confidence,
          .sequence = agent->sequence,
          .observed_at_ms = agent->observed_at,
          .expires_at_ms = agent->expires_at,
          .work_tree = agent->worktree,
          .final_message = agent->progress.finalMessage(),
          .plan_done = agent->progress.done(),
          .plan_total = agent->progress.total(),
          .plan_step = agent->progress.step(),
      };

      ++count;
    }

    for (std::size_t index = 0; index < count; ++index) {
      entries.atMut(index).cwd_label = directories[index].view();
      if (placeholder_titles[index]) {
        entries.atMut(index).session_title = placeholders[index].view();
      }
    }

    client.connection.send(AgentSnapshot{.revision = registry.revision() + model.workspace_revision, .entries = std::span{entries}.first(count)});
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
      if (auto* agent = agents_.findMut(pane.id, pane.generation)) {
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
    return DescriptionQueue::completeDescription(agents_, result);
  }

  template <EventLoop Poller, HistoryEventSink History>
  AgentProvider AgentService<Poller, History>::report(RuntimeModel& model, ClientSession& client, const ReportAgent& request) {
    auto& pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto* existing = agents_.findMut(pane.id, pane.generation);
    if (existing == nullptr && request.state == AgentReportState::continuing) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return request.provider;
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
    if (request.provider != AgentProvider::unknown) {
      return request.provider;
    }

    // A report that names no provider is by the one that claimed the pane.
    return agent.provider != AgentProvider::unknown ? agent.provider : agent.evidence.reporter;
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
        selected = &agent.get();
      }
    }

    return selected == nullptr ? ds::none : ds::Option{SessionFileRequest{.pane = selected->pane, .generation = selected->generation, .watch = selected->file_watch}};
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::completeSessionFile(const SessionFileResult& result, std::chrono::steady_clock::time_point now) {
    auto* agent = agents_.findMut(result.request.pane, result.request.generation);
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
      } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a title the agent cannot keep leaves the one it has
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
  tbc::mut_a<Pane> AgentService<Poller, History>::validateCommand(tbc::mut_a<RuntimeModel> model, ClientSession& client, const ReportAgentCommand& request) {
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

    constexpr std::size_t prompt_prefix_bytes = 192;
    ds::Array<char, prompt_prefix_bytes> prefix{};
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

      constexpr std::size_t sender_name_bytes = 64;
      const auto written = std::format_to_n(prefix.dataMut(), static_cast<std::ptrdiff_t>(prefix.size()), "[telar: from {}, pane {}] ", utf8Prefix(name, sender_name_bytes), sender->id);

      length = std::min(static_cast<std::size_t>(written.size), prefix.size());
    }

    panes.sendText(model.panes, client, request, {prefix.data(), length}, [this](const Pane& target, std::span<const Byte> bytes) {
      observeInput(target, bytes);
    });
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::acknowledge(const AcknowledgeAgent& request) noexcept {
    if (auto* agent = agents_.findMut(request.pane_id, request.pane_generation); agent != nullptr && agent->status == AgentStatus::done) {
      agent->acknowledged = true;
      if (agent->project(wallMilliseconds())) {
        projected(agent->pane, agent->generation);
      }
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::interrupt(RuntimeModel& model, Panes& panes, ClientSession& client, const InterruptAgent& request, bool focused) {
    // An interrupt is a key typed into a terminal.
    auto pane = Panes::requireTerminalGeneration(model.panes, request.pane_id, request.pane_generation);
    if (pane.core.exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (focused) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }

    auto* agent = agents_.findMut(pane.core.id, pane.core.generation);
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

    ds::Array<Byte, encoded_key_bytes> encoded{};
    const bool control_c = manifest->interrupt == AgentInterruptKey::control_c;
    const auto bytes = pane.body.terminal.encodeKey(control_c ? GHOSTTY_KEY_C : GHOSTTY_KEY_ESCAPE, control_c ? GHOSTTY_MODS_CTRL : 0, encoded.viewMut());
    const std::size_t repeats = manifest->interrupt == AgentInterruptKey::escape_twice ? 2 : 1;
    if (panes.admitInput(pane, bytes.size() * repeats)) {
      for (std::size_t index = 0; index < repeats; ++index) {
        enqueueInput(pane, bytes);
      }

      panes.flushInput(pane);
    }

    agent->report(ReportAgent{.state = AgentReportState::settling, .event = "Interrupted by telar"});
    agent->interrupt_at = now;
    agent->interrupt_revision = pane.body.terminal.contentRevision();
    projected(agent->pane, agent->generation);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::focused(const ClientStore& clients, const ClientLayouts& layouts, std::uint64_t pane) noexcept {
    return std::ranges::any_of(clients.items(), [&](const ClientSession* client) {
      return client != nullptr && client->role == ClientRole::interactive && !client->connection.flags().closing && layouts.focusedPane(client->identity) == pane;
    });
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
    auto* agent = agents_.findMut(pane.id, pane.generation);
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

        // What it last said shows on its card until it says something else.
        agent->progress.restore(pane.restored_final_message.view());
        agents_.changed();
      }

      pane.restored_agent.reset();
      pane.restored_final_message.clear();
      pane.restored_final_message.shrinkToFit();
    }

    if (changed) {
      projected(pane.id, pane.generation);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void AgentService<Poller, History>::observeProcess(Pane& pane, const ProcessProbeResult& observation) {
    observeProcess(pane, observation.identity, observation.provider);
    auto* agent = agents_.findMut(pane.id, pane.generation);
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
    auto* agent = agents_.findMut(pane.id, pane.generation);
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
      return findPane(model.panes, {.id = agent.pane, .generation = agent.generation}) == nullptr || (!agent.evidence.choose(wallMilliseconds()) && agent.observed_at != 0);
    });

    for (auto* pane : model.panes.items()) {
      if (pane == nullptr || pane->exit_status) {
        continue;
      }

      auto* agent = agents_.findMut(pane->id, pane->generation);
      if (agent == nullptr) {
        continue;
      }

      // The registry learns of the change once this agent is no longer borrowed from it.
      const auto title_revision = programTitle(*pane).revision;
      const bool revised = agent->cwd_revision != pane->cwd_revision || agent->title_revision != title_revision;
      if (revised) {
        agent->cwd_revision = pane->cwd_revision;
        agent->title_revision = title_revision;
      }

      // An interrupt settles on what the terminal shows after it.
      const auto terminal = asTerminal(pane);
      const bool settled = agent->interrupt_at && terminal && settleInterrupt(panes, focused(clients, layouts, pane->id), *terminal, *agent, now);
      const auto current_time = wallMilliseconds();

      const auto previous = agent->status;

      agent->evidence.expire(current_time);
      if (!agent->evidence.report) {
        agent->interrupt_at.reset();
        agent->interrupt_idle_at.reset();
      }

      // A turn that ends with time, as a settling report or a screen that outlasts its report, is heard as any other.
      if (agent->project(current_time) || settled) {
        if (alerts(*agent, previous)) {
          sounds_.push(*agent);
        }

        projected(agent->pane, agent->generation);
      }

      if (revised) {
        agents_.changed();
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

    if (auto* agent = agents_.findMut(pane, generation)) {
      descriptions_.project(pending, *agent);
      agent->sequence = ++sequence_;
    }

    agents_.changed();
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::alerts(const Agent& agent, AgentStatus previous) noexcept {
    return (agent.status == AgentStatus::done && previous == AgentStatus::working) || (agent.status == AgentStatus::blocked && previous != AgentStatus::blocked) || (agent.status == AgentStatus::failed && previous != AgentStatus::failed);
  }

  template <EventLoop Poller, HistoryEventSink History>
  bool AgentService<Poller, History>::settleInterrupt(Panes& panes, bool focused, PaneRef<TerminalBody> pane, Agent& agent, std::chrono::steady_clock::time_point now) {
    bool settled = false;

    if (hasIdleScreen(agent.provider)) {
      if (pane.body.terminal.contentRevision() <= agent.interrupt_revision || !pane.body.terminal.outputSettled()) {
        return false;
      }

      pane.body.terminal.refresh();
      const auto observation = AgentScreenReader{pane.body.terminal}.observe(agent.provider);
      if (observation.restored_draft && !agent.interrupt_draft_cleared && !focused) {
        ds::Array<Byte, encoded_key_bytes> encoded{};
        const auto bytes = pane.body.terminal.encodeKey(GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL, encoded.viewMut());
        if (panes.admitInput(pane, bytes.size())) {
          enqueueInput(pane, bytes);
          panes.flushInput(pane);
        }

        agent.interrupt_draft_cleared = true;
        agent.interrupt_at = now;
        agent.interrupt_idle_at.reset();
        agent.interrupt_revision = pane.body.terminal.contentRevision();
        return false;
      }

      if (observation.status != AgentStatus::ready || observation.restored_draft) {
        agent.interrupt_idle_at.reset();
        return false;
      }

      if (!agent.interrupt_idle_at) {
        agent.interrupt_idle_at = now;
      }

      // How long an interrupted agent's screen stays idle before it counts as ready.
      constexpr auto idle_settle = std::chrono::milliseconds{500};

      settled = now - *agent.interrupt_idle_at >= idle_settle;
    } else {
      settled = now - *agent.interrupt_at >= std::chrono::seconds{3};
    }

    if (settled) {
      // The turn telar stopped is idle, with no result to read.
      agent.interrupt_at.reset();
      agent.interrupt_idle_at.reset();
      agent.evidence.applyReport(ReportAgent{.state = AgentReportState::interrupted, .event = "Interrupted by telar"}, ObservationTime::now());
      if (hasIdleScreen(agent.provider)) {
        constexpr Byte idle_screen_confidence = 94;

        agent.evidence.applyScreen(AgentSignal{.provider = agent.provider, .status = AgentStatus::ready, .confidence = idle_screen_confidence, .identity_confirmed = true, .ready_confirmed = true}, ObservationTime::now(), agent.status, true);
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
  tbc::mut_a<Pane> AgentService<Poller, History>::authorize(tbc::mut_a<PaneStore> panes, const ClientSession& client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider) {
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
          .sound = agent.status == AgentStatus::blocked || agent.status == AgentStatus::failed ? AgentSound::needs_input : AgentSound::ready,
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

  tbc::val_a<std::string_view> ownDirectory(tbc::mut_a<LaunchDirectory> storage, std::string_view directory) {
    if (directory.size() > launch_directory_bytes) {
      throw RequestError{FailureCode::invalid_request, "working directory is too long"};
    }

    storage.assign(directory);
    return storage.view();
  }

  tbc::val_a<Launch> resolveLaunchDirectory(const RuntimeModel& model, const ClientSession& client, tbc::val_a<Launch> launch, tbc::mut_a<LaunchDirectory> directory, LaunchDirectoryScope scope) {
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

    launch.cwd = ownDirectory(directory, pane->cwd);
    launch.cwd_source = 0;
    return launch;
  }

  PluginDelivery::PluginDelivery(LimitService& limits) noexcept
      : limits_(limits) {}

  void PluginDelivery::reportMetrics(const plugins::TapMetrics& now) {
    reportGrowth(now.dropped_queue, previous_.dropped_queue, {.name = "plugins.tap.queue_depth", .noun = "exchanges", .value = plugins::Limits::queue_depth});
    reportGrowth(now.dropped_bytes, previous_.dropped_bytes, {.name = "plugins.tap.max_held_bytes", .noun = "bytes", .value = plugins::Limits::held_bytes});
    reportGrowth(now.timeouts, previous_.timeouts, {.name = "plugins.tap.reply_timeout_ms", .noun = "ms", .value = std::chrono::duration_cast<std::chrono::milliseconds>(plugins::Limits::reply_deadline).count()});
    reportGrowth(now.disabled, previous_.disabled, {.name = "plugins.tap.restart_limit", .noun = "restarts in 10 min", .value = plugins::Limits::restarts});
    previous_ = now;
  }

  void PluginDelivery::publish(ClientStore& clients, const NotificationBody& body) {
    const Notification notification{body};
    ds::Array<Byte, validation_bytes> validation{};
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
  tbc::val_a<const ConfigureTerminalColors*> WorkspaceService<Poller, History>::ownerColors(const WorkspaceStore& workspaces, tbc::ref_a<ClientStore> clients, std::uint64_t workspace) noexcept {
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
      const auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), *request.launch, directory);
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
          pane = createAt(model, panes, clients, {.client_id = client_id, .location = TabLocation{.workspace = WorkspaceLocation{.id = workspace->id}, .tab_id = workspace->tabs.front().id}, .launch = launch, .size = request.size});
          created = true;
        }
      } else {
        pane = createRoot(model, panes, clients, {.client_id = client_id, .launch = launch, .size = request.size});
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
    const auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), request.launch, directory);

    if (request.create_cwd && request.launch.cwd_source == 0) {
      createDirectories(launch.cwd);
    }

    const auto pane = createRoot(model, panes, clients, {.client_id = client_id, .launch = launch, .size = request.size, .name = request.name, .replace_view = true});

    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createTab(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const CreateTab& request) {
    createTab(model, panes, clients, Asked{.client_id = client_id}, request);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createTab(RuntimeModel& model, Panes& panes, ClientStore& clients, Asked asked, const CreateTab& request) {
    const auto [client_id, kind] = asked;

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
      const auto pane = createAt(model, panes, clients, {.client_id = client_id, .location = TabLocation{.workspace = request.workspace, .tab_id = tab_id}, .launch = launch, .size = request.size, .kind = kind});

      ++model.next_tab_id;
      const auto& opened = Panes::require(model.panes, pane);
      const auto& tabs = require(model.workspaces, request.workspace).tabs;

      announceKind(requireClient(clients, client_id), opened);
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
        launch.cwd = ownDirectory(directory, workspace.path);
      }

      const auto pane = panes.launch(model, {.owner_colors = owner_colors, .bare_prompt = bare_prompt, .location = TabLocation{.workspace = {.id = request.workspace}, .tab_id = tab_id}, .size = request.size}, launch).core.id;

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
    createPane(model, panes, clients, Asked{.client_id = client_id}, request);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createPane(RuntimeModel& model, Panes& panes, ClientStore& clients, Asked asked, const CreatePane& request) {
    const auto [client_id, kind] = asked;

    const auto* workspace = model.workspaces.find(request.location.workspace.id);
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, request.location))) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    const auto pane = createAt(model, panes, clients, {.client_id = client_id, .location = request.location, .launch = request.launch, .size = request.size, .kind = kind});

    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createEditor(RuntimeModel& model, Panes& panes, ClientStore& clients, EditorRequest asked, const NvimProvision& provision) {
    const auto client_id = asked.client_id;
    const auto& request = asked.request;
    // The program, the flag that makes it speak its UI protocol on its pipes, telar's own
    // configuration, where the cursor starts and then the files.
    constexpr std::size_t cursor_capacity = 48;
    constexpr std::size_t fixed_arguments = 5;
    ds::Array<std::string_view, max_nvim_files + fixed_arguments> arguments;
    ds::Array<char, cursor_capacity> cursor{};
    std::size_t count = 0;

    arguments.atMut(count++) = provision.program();
    arguments.atMut(count++) = "--embed";
    // Never the user's configuration: telar's own, or none when it could not be written.
    arguments.atMut(count++) = "-u";
    arguments.atMut(count++) = provision.ownInit().empty() ? std::string_view{"NONE"} : provision.ownInit();

    if (request.line != 0 && !request.files.empty()) {
      // Two numbers the runtime writes itself: nothing a client sent is run as a command.
      const auto written = std::format_to_n(cursor.dataMut(), cursor.size(), "+call cursor({},{})", request.line, std::max<std::uint32_t>(request.column, 1));

      arguments.atMut(count++) = std::string_view{cursor.data(), static_cast<std::size_t>(written.size)};
    }

    for (const auto file : request.files) {
      // A name that starts as an option would be read as one.
      if (file.starts_with('-') || file.starts_with('+')) {
        throw RequestError{FailureCode::invalid_request, "A file to edit cannot start with - or +"};
      }

      arguments.atMut(count++) = file;
    }

    const Launch launch{.cwd = request.cwd, .arguments = arguments.view().first(count)};

    if (request.new_tab) {
      createTab(model, panes, clients, Asked{.client_id = client_id, .kind = PaneKind::nvim}, CreateTab{.request_id = request.request_id, .workspace = request.location.workspace, .size = request.size, .launch = launch});
    } else {
      createPane(model, panes, clients, Asked{.client_id = client_id, .kind = PaneKind::nvim}, CreatePane{.request_id = request.request_id, .location = request.location, .size = request.size, .launch = launch});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::createExplorer(RuntimeModel& model, Panes& panes, ClientStore& clients, std::uint64_t client_id, const CreateExplorerPane& request) {
    const auto location = request.location;
    const auto* workspace = model.workspaces.find(location.workspace.id);
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, location))) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    for (const auto identity : tab->panes) {
      if (const auto* pane = model.panes.find(identity); pane != nullptr && pane->kind() == PaneKind::explorer && !pane->close_requested) {
        throw RequestError{FailureCode::invalid_request, "This tab already has an explorer"};
      }
    }

    if (tab->panes.size() == maximum_panes_per_tab) {
      throw RequestError{FailureCode::resource_limit, "Tab pane limit reached"};
    }

    if (!acquireGeometry(model.panes, model.metrics, requireClient(clients, client_id), require(model.workspaces, location.workspace))) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }

    // The workspace's directory has storage of its own, which the new pane copies.
    LaunchDirectory directory;
    const auto started_in = ownDirectory(directory, require(model.workspaces, location.workspace).path);
    const auto pane = panes.launchExplorer(model, {.location = location, .size = request.size}, started_in).core.id;

    try {
      requireExplorer(model.panes, pane).body.keep(request.layout);
      panes.attach(model, requireClient(clients, client_id), pane, request.size);
      requireTab(model.workspaces, location).panes.push(pane);
    } catch (...) {
      panes.remove(model, clients, pane);
      throw;
    }

    ++model.workspace_revision;
    notify(location.workspace.id, client_id);
    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::renameWorkspace(RuntimeModel& model, ClientSession& client, const RenameWorkspace& request) {
    require(model.workspaces, request.workspace).name.assign(request.name);
    ++model.workspace_revision;
    notify(request.workspace.id, client.id);
    workspaceSnapshot(model, client, RequestWorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace});
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
    const auto* tab = workspace.tab(request.location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    const auto from = static_cast<std::size_t>(tab - workspace.tabs.data());
    auto destination = from;

    if (request.relative_to) {
      const auto* relative = workspace.tab(*request.relative_to);
      if (relative == nullptr) {
        throw RequestError{FailureCode::tab_not_found, "Relative tab does not exist"};
      }

      destination = static_cast<std::size_t>(relative - workspace.tabs.data());
      if (request.direction == TabMoveDirection::previous && from < destination) {
        --destination;
      }

      if (request.direction == TabMoveDirection::next && from > destination) {
        ++destination;
      }
    } else if (request.direction == TabMoveDirection::previous && from != 0) {
      destination = from - 1;
    } else if (request.direction == TabMoveDirection::next && from + 1 < workspace.tabs.size()) {
      destination = from + 1;
    }

    const auto tabs = workspace.tabs.viewMut();

    if (from < destination) {
      const auto moved = tabs.subspan(from, destination - from + 1);

      std::ranges::rotate(moved, std::next(moved.begin()));
    } else if (destination < from) {
      const auto moved = tabs.subspan(destination, from - destination + 1);

      std::ranges::rotate(moved, std::prev(moved.end()));
    }

    ++model.workspace_revision;
    notify(request.location.workspace.id, client.id);
    client.connection.send(TabMoved{.request_id = request.request_id, .location = request.location, .position = static_cast<std::uint16_t>(destination)});
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::closePane(RuntimeModel& model, const ClientSession& client, const ClosePane& request) {
    if (client.attachment(request.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "pane not attached"};
    }

    requestClose(Panes::require(model.panes, request.pane_id));
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::collectExited(RuntimeModel& model, Panes& panes, ClientStore& clients) {
    for (std::size_t slot = 0; slot < model.panes.items().size(); ++slot) {
      auto* pane = model.panes.items()[slot];
      if (pane == nullptr || !pane->output_closed || !pane->exit_status || pane->observers != 0) {
        continue;
      }

      // What a terminal last showed is kept for a client that reads it after the pane is gone.
      if (const auto terminal = asTerminal(pane)) {
        retainFinalText(model.exited_panes, *terminal);
      }

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
    const auto* workspace = model.workspaces.find(identity);

    while (workspace != nullptr && !workspace->tabs.empty()) {
      const auto closed = removeTab(model, TabLocation{.workspace = WorkspaceLocation{.id = identity}, .tab_id = workspace->tabs.front().id});

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
    ds::Array<WorkspaceListEntry, WorkspaceStore::capacity> entries{};
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
        if (client != nullptr && client->workspace && client->connection.flags().negotiated && !client->connection.flags().closing) {
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
    const auto* workspace = model.workspaces.find(location.workspace.id);
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
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
  void WorkspaceService<Poller, History>::broadcastTabClosed(ClientStore& clients, const TabClosed& closed, const Seen& seen) noexcept {
    deliver(clients, [&](const ClientSession& client) {
      return client.connection.flags().negotiated && client.workspace == closed.location.workspace.id;
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
    const auto* tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    const auto previous = workspace->tabs.size() == 1 ? previousWorkspace(model.workspaces, workspace->id) : ds::none;

    // The tab's panes, copied: closing one changes the pane store while the tab lies in the
    // workspaces, as Rust copies ids out of one collection before mutating another.
    ds::Array<std::uint64_t, maximum_panes_per_tab> closing{};
    const auto count = std::min(tab->panes.size(), closing.size());

    std::ranges::copy(tab->panes.view().first(count), closing.dataMut());
    for (const auto identity : std::span{closing}.first(count)) {
      if (auto* pane = model.panes.find(identity)) {
        requestClose(*pane);
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
  void WorkspaceService<Poller, History>::retainFinalText(ExitedPanes& exited, PaneRef<TerminalBody> pane) noexcept {
    const auto exit_code = pane.core.exitCode();

    try {
      TextReader reader{memory_, pane.body.terminal, ExitedPanes::maximum_bytes};

      reader.read(PaneTextSource::recent, ExitedPanes::kept_rows);
      const auto rows = pane.body.terminal.totalRows();

      exited.record({.id = pane.core.id, .generation = pane.core.generation}, PaneText{
                                                                                  .truncated = reader.truncated() || rows > ExitedPanes::kept_rows,
                                                                                  .text = reader.text(),
                                                                                  .exit_code = exit_code,
                                                                              });
    } catch (...) {
      exited.record({.id = pane.core.id, .generation = pane.core.generation}, PaneText{.truncated = true, .exit_code = exit_code});
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  std::uint64_t WorkspaceService<Poller, History>::createRoot(RuntimeModel& model, Panes& panes, ClientStore& clients, const WorkspaceOpening& opening) {
    const auto& [client_id, launch, size, name, replace_view] = opening;

    if (model.next_tab_id == 0 || model.workspaces.nextCounter() == 0) {
      throw RequestError{FailureCode::resource_limit, "could not create workspace"};
    }

    const auto workspace_id = model.workspaces.nextId();
    auto workspace = ds::makeBox<Workspace>(memory_, memory_, WorkspaceSpec{.id = workspace_id, .path = launch.cwd, .name = name});
    const auto tab_id = model.next_tab_id;

    workspace.getMut().tabs.emplace(memory_, tab_id, std::string_view{});
    model.workspaces.insertProvisional(workspace_id, std::move(workspace));
    ds::Option<std::uint64_t> pane;

    try {
      const TabLocation location{.workspace = {.id = workspace_id}, .tab_id = tab_id};
      const auto* requester = clients.find(client_id);

      pane = panes.launch(model, {.bare_prompt = requester != nullptr && requester->bare_prompt, .location = location, .size = size}, launch).core.id;
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
  std::uint64_t WorkspaceService<Poller, History>::createAt(RuntimeModel& model, Panes& panes, ClientStore& clients, const TabOpening& opening) {
    const auto& [client_id, location, requested, size, kind] = opening;
    auto launch = requested;

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

    // The workspace's directory has storage of its own: the launch may still view `directory`.
    LaunchDirectory fallback;

    if (launch.cwd.empty()) {
      launch.cwd = ownDirectory(fallback, require(model.workspaces, location.workspace).path);
    }

    const PanePlacement placement{.owner_colors = &client.colors, .bare_prompt = client.bare_prompt, .location = location, .size = size};
    const auto pane = kind == PaneKind::nvim ? panes.launchEditor(model, placement, launch).core.id : panes.launch(model, placement, launch).core.id;

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

    constexpr mode_t owner_only = 0700;

    std::ranges::copy(path, directory.dataMut());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (directory[index] != '/' && directory[index] != '\0') {
        continue;
      }

      const char separator = directory[index];

      directory.atMut(index) = '\0';
      if (::mkdir(directory.data(), owner_only) != 0 && sys::lastError() != EEXIST) {
        throw SystemError{"create working directory"};
      }

      directory.atMut(index) = separator;
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::announceKind(ClientSession& client, const Pane& pane) {
    if (pane.kind() != PaneKind::terminal) {
      client.connection.send(PaneKindNotice{.pane_id = pane.id, .kind = pane.kind()});
    }

    ExplorerScratch scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): the decoder writes the windows it hands back, so zeroing them first would be waste

    // An explorer says where its windows are, to a client that did not give them.
    if (const auto kept = explorerKept(pane, scratch)) {
      client.connection.send(*kept);
    }
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorkspaceService<Poller, History>::sendOpened(ClientSession& client, std::uint64_t request, const Pane& pane, bool created, GenerationField generation) {
    announceKind(client, pane);
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
      const auto* pane = findPane(model.panes, {.id = *request.created_by, .generation = client.verified_generation});
      if (pane == nullptr || pane->exit_status || !client.verifiedFor(*pane)) {
        throw RequestError{FailureCode::foreign_process, "Only a process inside the pane may register for it"};
      }
    }

    const auto result = model.worktrees.registerEntry(request);

    ++model.workspace_revision;
    client.connection.send(result);
  }

  template <EventLoop Poller, HistoryEventSink History>
  void WorktreeService<Poller, History>::launch(RuntimeModel& model, LaunchServices services, ClientStore& clients, std::uint64_t client_id, const LaunchWorktree& request) {
    constexpr std::size_t workspace_title_bytes = 128;
    constexpr std::size_t command_label_bytes = 48;

    const auto& entry = require(model.worktrees, request.worktree);
    auto* found = entry.workspace ? model.workspaces.find(*entry.workspace) : nullptr;
    const bool created = found == nullptr;
    auto workspace = found == nullptr ? std::uint64_t{0} : found->id;

    if (created) {
      workspace = model.workspaces.nextId();
      const auto title = entry.title.view().empty() ? entry.branch.view() : entry.title.view();
      auto owned = ds::makeBox<Workspace>(memory_, memory_, WorkspaceSpec{.id = workspace, .path = entry.path, .name = utf8Prefix(title, workspace_title_bytes)});

      model.workspaces.insertProvisional(workspace, std::move(owned));
    }

    std::uint64_t pane = 0;

    try {
      auto launch = request.launch;
      LaunchDirectory directory;

      launch.cwd = ownDirectory(directory, require(model.worktrees, request.worktree).path);
      launch.cwd_source = 0;
      pane = services.workspaces.launchBackground(model, services.panes, Workspaces::ownerColors(model.workspaces, clients, workspace), Workspaces::ownerBarePrompt(model.workspaces, clients, workspace), LaunchTab{.request_id = request.request_id, .workspace = workspace, .label = request.label, .size = request.size, .launch = launch});
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

    current.command_label.assign(utf8Prefix(program.substr(program.rfind('/') + 1), command_label_bytes));
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
      const auto* const name = result.timeout == GitProbeTimeout::status ? "gitstatus.status_timeout" : "gitstatus.base_distance_timeout";

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
        changed |= applyMeasurement(*entry, result);
      } else {
        entry->probe_failures = std::min(entry->probe_failures + 1, 2U);
      }
    }

    model.workspace_revision += static_cast<std::uint64_t>(changed);
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
        listener_(setAsideBeforeListening(memory, options)),
        model_(memory, options.graphics),
        clients_(memory),
        admissions_(poller_, limits_),
        client_layouts_(memory),
        panes_(memory, poller_, limits_, PaneLaunchOptions{.socket = options.socket, .proxy = proxy, .control_policy = options.control_policy, .shell_integration = options.shell_integration, .ssh_integration = options.ssh_integration, .agent_plans = options.agent_plans}, background),
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
        monitor_(memory, process_inspector_, ProcessTable{memory}, NativeHostDetail{}),
        workspace_git_(limits_, memory),
        shell_git_(memory),
        data_home_(memory, options.data_home),
        editor_provision_(memory),
        editor_configuration_(memory, options.editor_configuration),
        words_(memory, options.configuration_directory),
        agent_files_(memory),
        file_moves_(memory),
        descriptions_(memory, background_, options.descriptions),
        telemetry_(options.socket, proxy.status()) {
    model_.cli_executable = options.cli_executable;
    model_.capture_output = options.capture_output;
    model_.manifests = *options.manifests;
    agents_.enableDescriptions(descriptions_.enabled());
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
    poller_.watch(monitor_.descriptor(), eventToken(EventSource::worker, 0));
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
    auto client = ds::makeBox<ClientSession>(memory_, memory_, identity, std::move(descriptor));

    client.getMut().connection.flagsMut().negotiated = true;
    client.getMut().peer_identity = process_inspector_.peer(client->connection.descriptor());
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
    } catch (...) { // NOLINT(bugprone-empty-catch): the client's executions are let go best effort; dropping the client goes on
    }

    background_.cancel(identity);
    deferred_reports_.cancel(*client);
    client->connection.flagsMut().closing = true;
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
        if (client->connection.flags().read_paused) {
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
    if (pane == nullptr) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    visitPaneAs(*pane, [&](auto kind) {
      paneEvent(kind, event);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::paneEvent(PaneRef<TerminalBody> pane, const Event& event) {
    if (pane.body.process->descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    const auto identity = pane.core.id;

    try {
      if (event.kind == EventKind::readable) {
        const auto mode = model_.panes.size() == 1 ? TerminalBody::ReadMode::burst : TerminalBody::ReadMode::once;
        if (!telar::runtime::read(pane, mode)) {
          poller_.remove(pane.body.process->descriptor());
        }
      }

      panes_.flushInput(pane);
      observations_.observe(model_, agents_, identity);
      if (const auto observed = asTerminal(model_.panes.find(identity))) {
        media_.updateReadInterest(*observed);
      }
    } catch (const std::exception&) {
      if (const auto failed = asTerminal(model_.panes.find(identity))) {
        panes_.failOutput(*failed);
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::paneEvent(PaneRef<ExplorerBody> /*pane*/, const Event& /*event*/) noexcept {}

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::paneEvent(PaneRef<NvimBody> pane, const Event& event) {
    try {
      if (event.descriptor == pane.body.process->output()) {
        if (!telar::runtime::read(pane)) {
          panes_.closeEditorOutput(pane);
        }
      } else if (event.descriptor == pane.body.process->error()) {
        if (!pane.body.readErrors()) {
          panes_.closeEditorErrors(pane);
        }
      } else if (event.descriptor != pane.body.process->input()) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
        return;
      }

      // What Neovim said may have queued an answer, and its input may take what was left.
      panes_.flushEditor(pane);
    } catch (const std::exception&) {
      panes_.failEditor(pane);
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

            return client != nullptr && !client->connection.flags().read_paused;
          },
          [&](std::span<const Byte> payload, DecodeStorage& storage) {
            if (!requireClient(clients_, identity).connection.flags().closing) {
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
      client->connection.flagsMut().buffered_requests = remaining;
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
          observeReporter(identity, *reporter);
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
  void Runtime<Poller, Background>::observeReporter(std::uint64_t identity, ReporterIdentity reporter) {
    try {
      observations_.observe(model_, agents_, reporter.pane);
    } catch (...) {
      auto& deferred = requireClient(clients_, identity);

      deferred_reports_.cancel(deferred);
      deferred.deferred_report.payload.clear();
      throw;
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
    worktrees_.launch(model_, {.workspaces = workspaces_, .panes = panes_}, clients_, identity, message);
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
    const auto provider = agents_.report(model_, requireClient(clients_, identity), message);

    // The line of a tool names what the agent touches: the explorer's files keep it for who asks.
    if constexpr (requires(Background& background, const TouchNote& note) { background.noteTouch(note); }) {
      if (const auto pane = asTerminal(model_.panes.find(message.pane_id)); pane && message.event.starts_with(agent_tool_mark)) {
        background_.noteTouch({.pane = message.pane_id, .actor = TouchActor::agent, .provider = provider, .text = message.event, .directory = std::string_view{pane->core.cwd}, .seconds = secondsNow()});
      }
    }
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
  void Runtime<Poller, Background>::handle(std::uint64_t /*identity*/, const AcknowledgeAgent& message) {
    agents_.acknowledge(message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryAgents& /*message*/) {
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
    // Words are completed for the shell of a terminal.
    const auto pane = asTerminal(model_.panes.find(message.pane_id));
    if (!pane) {
      throw RequestError{FailureCode::pane_not_found, "Could not complete words"};
    }

    // A remote shell's commands, branches and hosts are not this host's to read.
    if (pane->body.shell_state.remote) {
      client.connection.send(CompletionWords{.request_id = message.request_id, .truncated = true, .words = {}});
      return;
    }

    auto request = makeWordRequest(client, message.request_id, message.provider, message.prefix, pane->body);

    request.directory.assign(pane->body.shell_zones && !pane->body.shell_zones->directory().empty() ? pane->body.shell_zones->directory() : std::string_view{pane->core.cwd});
    request.home.assign(processHome());
    failDropped(client, words_.request(request));
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestCommandSpec& message) {
    auto& client = requireClient(clients_, identity);
    // A command's spec is asked for the shell of a terminal.
    const auto pane = asTerminal(model_.panes.find(message.pane_id));
    if (!pane) {
      throw RequestError{FailureCode::pane_not_found, "Could not find a command spec"};
    }

    auto request = makeWordRequest(client, message.request_id, CompletionProvider::command, message.command, pane->body);

    // A remote shell's commands are not this host's to find: the spec of any command it names.
    request.remote = pane->body.shell_state.remote;
    request.spec = true;
    request.known_digest = message.known_digest;
    failDropped(client, words_.request(request));
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::failDropped(ClientSession& client, ds::Option<std::uint64_t> dropped) {
    // Every request is answered: the oldest one the service let go to make room fails.
    if (dropped) {
      client.connection.send(RequestFailed{.request_id = *dropped, .code = FailureCode::resource_limit, .message = "Too many completion requests are waiting"});
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  tbc::val_a<WordRequest> Runtime<Poller, Background>::makeWordRequest(const ClientSession& client, std::uint64_t request_id, CompletionProvider provider, std::string_view prefix, tbc::holds<const TerminalBody&, tbc::lt::a> pane) const {
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
    const auto* source = message.pane_generation == 0 ? model_.panes.find(message.pane_id) : findPane(model_.panes, {.id = message.pane_id, .generation = message.pane_generation});
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
      for (const auto* stored : model_.panes.items()) {
        // An editor to reuse is the program in the foreground of a terminal.
        const auto pane = asTerminal(stored);
        if (!pane || pane->core.exit_status || pane->core.close_requested || pane->core.location.workspace.id != source->location.workspace.id || pane->core.location.tab_id != source->location.tab_id || identifyEditor(pane->core.process_cache.identified.name.view()) != editor) {
          continue;
        }

        const auto group = ::tcgetpgrp(pane->body.process->descriptor());
        const auto process = group > 0 ? process_inspector_.identity(group) : ds::none;
        if (process && context.editor_candidate_count < context.editor_candidates.size()) {
          context.editor_candidates.atMut(context.editor_candidate_count++) = {.pane = pane->core.id, .generation = pane->core.generation, .process = *process};
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
      client.connection.send(CommandSuggestion{.request_id = message.request_id, .status = SuggestionStatus::unavailable});
      return;
    }

    // A suggestion reads what a terminal shows.
    auto pane = asTerminal(model_.panes.find(message.pane_id));
    if (!pane) {
      client.connection.send(CommandSuggestion{.request_id = message.request_id, .status = SuggestionStatus::failed});
      return;
    }

    try {
      // The screen a suggestion reads: its last rows, as much of them as a prompt keeps.
      constexpr std::size_t suggestion_screen_bytes = 4096;
      constexpr std::uint16_t suggestion_screen_rows = 24;
      TextReader reader{memory_, pane.getMut().body.terminal, suggestion_screen_bytes};

      reader.read(PaneTextSource::screen, suggestion_screen_rows);
      const auto prompt = suggestionPrompt(memory_, {.cwd = pane->core.cwd, .screen = reader.text(), .request = message.text});

      submitBackground(background_, client, message, RequestContext{.prompt = prompt});
    } catch (const RequestError&) {
      client.connection.send(CommandSuggestion{.request_id = message.request_id, .status = SuggestionStatus::failed});
    } catch (const std::bad_alloc&) {
      client.connection.send(CommandSuggestion{.request_id = message.request_id, .status = SuggestionStatus::failed});
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
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CreateNvimPane& message) {
    // A variable of the runtime's environment, kept: what the next one read returns may be
    // where this one was.
    const auto variable = [&](const char* name) {
      const char* value = std::getenv(name); // NOLINT(concurrency-mt-unsafe): the runtime does not change its environment once it started

      return ds::String<ConcurrentMemory>{memory_, value == nullptr ? std::string_view{} : std::string_view{value}};
    };

    const auto configured = variable("TELAR_NVIM");

    // A Neovim that came in telar's own package: under share/, beside the directory of its
    // programs.
    ds::String<ConcurrentMemory> packaged{memory_, "../share/telar/nvim/"};

    packaged.append(pinnedNeovim());
    packaged.append("/bin/nvim");

    const auto shipped = ExecutablePath::sibling({packaged.view()});

    editor_provision_.resolve({.data_home = data_home_.view(), .configured = configured.view(), .shipped = shipped ? shipped->view() : std::string_view{}});
    workspaces_.createEditor(model_, panes_, clients_, {.client_id = identity, .request = message}, editor_provision_);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimInput& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.input(textView(message.keys));
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimPaste& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.paste(textView(message.text));
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimMouse& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.mouse(message);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimFocus& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      editor.focus(message.focused);
      return true;
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimPromptReply& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.answer({.id = message.prompt_id, .accepted = message.accepted, .index = message.index, .text = message.text});
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimOpen& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.open({.path = message.path, .line = message.line, .column = message.column, .in = message.in});
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimNavigate& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.navigate(message.direction);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimMenuSelect& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.selectMenu(message.item, message.accept);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimBuffers& message) {
    const auto& client = requireClient(clients_, identity);
    auto pane = requireNvim(model_.panes, message.pane_id);

    if (client.attachment(message.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "The editor's buffers are listed for a client that shows it"};
    }

    // One question at a time: a newer one takes the place of the one before.
    auto& query = pane.body.buffer_query.emplace();

    query.client = client.id;
    query.request_id = message.request_id;
    query.limit = message.limit;
    query.query.assign(message.query);
    panes_.editorRequest(model_, client, message.pane_id, [&](NvimEditor& editor) {
      return editor.listBuffers(message.request_id);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimPreview& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.preview({.path = message.path, .line = message.line, .column = message.match_column}, {.row = message.row, .column = message.column, .columns = message.columns, .rows = message.rows}, message.match_bytes);
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimList& message) {
    panes_.editorRequest(model_, requireClient(clients_, identity), message.pane_id, [&](NvimEditor& editor) {
      return editor.list(message.places);
    });
  }

  // A client's editor configuration replaces this machine's: the window brings its own to each
  // machine it connects to. It is small and comes once a connection, so it is written here.
  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const NvimConfiguration& message) {
    auto& client = requireClient(clients_, identity);

    if (editor_configuration_.empty()) {
      throw RequestError{FailureCode::invalid_request, "This runtime has no directory for the editor's configuration"};
    }

    try {
      static_cast<void>(mirrorNvimConfiguration(memory_, editor_configuration_.view(), message.files));
    } catch (const std::invalid_argument&) {
      throw RequestError{FailureCode::invalid_request, "A path of the editor's configuration is not one it may hold"};
    }

    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const FindText& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ListDirectory& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const MeasureDirectory& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryChanges& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const InspectFile& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ChangeFiles& message) {
    const auto& client = requireClient(clients_, identity);
    const bool edits = std::ranges::any_of(model_.panes.items(), [](auto* stored) {
      return static_cast<bool>(asNvim(stored));
    });

    // Only an editor is told where a file went: without one nothing is kept.
    if (edits) {
      file_moves_.asked(client.id, message);
    }

    submitBackground(background_, client, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const UndoFileChanges& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CommitChanges& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const LocateHome& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadFile& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const WriteFile& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const EndFileWrite& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryTouches& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const KeepPlaces& message) {
    static_cast<void>(requireClient(clients_, identity));
    client_layouts_.keepPlaces(message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const CreateExplorerPane& message) {
    workspaces_.createExplorer(model_, panes_, clients_, identity, message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const KeepExplorer& message) {
    static_cast<void>(requireClient(clients_, identity));
    auto explorer = requireExplorer(model_.panes, message.pane_id);

    explorer.body.keep(message.layout);
    // The pane is where its current window is, when that is on this machine. The count grows
    // either way: the windows are part of the session written to disk, which it tells of.
    if (const auto& current = message.layout.windows[message.layout.current]; current.machine.empty() && !current.root.empty()) {
      explorer.core.cwd.assign(current.root);
    }

    ++explorer.core.cwd_revision;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryPlaces& message) {
    client_layouts_.publishPlaces(message.request_id, requireClient(clients_, identity));
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::relay(PaneRef<NvimBody> pane) {
    const auto pulse = pane.body.editor.takePulse();
    if (pulse.listed) {
      answerBuffers(pane);
    }

    auto* driver = clients_.find(pane.body.driver);
    if (driver == nullptr || driver->attachment(pane.core.id) == nullptr) {
      return;
    }

    // What is yanked to a clipboard register is copied where the user types when the runtime's
    // policy lets programs write the clipboard. What runs in Neovim may yank without the person,
    // so `ask` holds it back as it holds back a terminal's program while no client can ask.
    if (pulse.copied && panes_.controlPolicy().clipboard_write == control::Access::allow) {
      driver->clipboard.replace(pane.core.id, byteView(pane.body.editor.clipboard()));
    }

    if (pulse.navigated) {
      driver->connection.send(NvimNavigated{.pane_id = pane.core.id, .direction = *pulse.navigated});
    }

    if (pulse.pick) {
      driver->connection.send(NvimPick{.pane_id = pane.core.id, .source = *pulse.pick});
    }

    if (pulse.opened) {
      driver->connection.send(NvimLink{.pane_id = pane.core.id, .uri = pane.body.editor.link()});
    }

    if (pulse.explore) {
      driver->connection.send(NvimExplore{.pane_id = pane.core.id, .path = pane.body.editor.explored()});
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::answerBuffers(PaneRef<NvimBody> pane) {
    const auto& listed = pane.body.editor.buffers();
    // An answer to a query asked before the one waiting leaves that one waiting for its own.
    if (!pane.body.buffer_query || pane.body.buffer_query->request_id != listed.token) {
      return;
    }

    const auto query = std::exchange(pane.body.buffer_query, ds::none);
    auto* client = clients_.find(query->client);
    if (client == nullptr || pane.core.cwd.view().empty()) {
      return;
    }

    struct Ranked {
      std::int32_t score = 0;
      std::uint32_t name = 0;
    };

    const std::string_view text{listed.text.data(), listed.text.size()};
    const auto wanted = query->query.view();
    const auto limit = std::min<std::size_t>(query->limit, FindPaths::maximum_limit);
    FuzzyMatch<ConcurrentMemory> matcher{memory_};
    ds::Array<Ranked, FindPaths::maximum_limit> ranked{};
    std::size_t count = 0;
    bool truncated = false;

    for (std::uint32_t index = 0; index < listed.names.size(); ++index) {
      // Without a query the names stay as Neovim gave them, the most recently used first.
      const auto score = wanted.empty() ? ds::Option<std::int32_t>{-static_cast<std::int32_t>(index)} : matcher.score(listed.names[index].of(text), wanted);
      if (!score) {
        continue;
      }

      auto place = std::min(count, limit);

      while (place > 0 && ranked[place - 1].score < *score) {
        --place;
      }

      if (place == limit) {
        truncated = true;
        continue;
      }

      truncated = truncated || count == limit;
      count = std::min(count + 1, limit);
      std::ranges::move_backward(ranked.viewMut().subspan(place, count - place - 1), ranked.viewMut().subspan(place + 1, count - place - 1).end());
      ranked.atMut(place) = {.score = *score, .name = index};
    }

    // A match marks at most one place for each byte of the query.
    constexpr std::size_t positions_each = FindPaths::maximum_query_bytes;
    ds::Array<std::uint16_t, FindPaths::maximum_limit * positions_each> positions{};
    ds::Array<PathMatch, FindPaths::maximum_limit> matches{};
    // Lent once: each match views its own piece of it.
    const auto marked = positions.viewMut();

    for (std::size_t index = 0; index < count; ++index) {
      const auto name = listed.names[ranked[index].name].of(text);
      const auto marks = marked.subspan(index * positions_each, std::min<std::size_t>(wanted.size(), positions_each));

      if (!wanted.empty()) {
        static_cast<void>(matcher.score(name, wanted, marks));
      }

      matches.atMut(index) = {.path = name, .kind = PathKind::file, .positions = wanted.empty() ? std::span<const std::uint16_t>{} : std::span<const std::uint16_t>{marks}};
    }

    client->connection.send(PathResults{.request_id = query->request_id, .root = pane.core.cwd.view(), .scanned = static_cast<std::uint32_t>(listed.names.size()), .complete = true, .truncated = truncated, .matches = matches.view().first(count)});
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
    if (const auto pane = ClipboardService::complete(model_.panes, requireClient(clients_, identity), message)) {
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
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ReadPaneTheme& message) {
    const auto* pane = findPane(model_.panes, {.id = message.pane_id, .generation = message.pane_generation});
    const auto* owner_colors = pane == nullptr ? nullptr : Workspaces::ownerColors(model_.workspaces, clients_, pane->location.workspace.id);

    const auto reply = Panes::readTheme(model_.panes, owner_colors, message);

    requireClient(clients_, identity).connection.send(reply);
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
    panes_.detach(model_, clients_, {.client = identity, .pane = message.pane_id});
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const FrameAck& message) {
    if (auto* attachment = requireClient(clients_, identity).attachmentMut(message.pane_id)) {
      if (attachment->kind == PaneKind::nvim) {
        // An editor's client applied the frame it was last sent; an older one names nothing new.
        if (message.frame_id == attachment->editor_sent) {
          attachment->editor_seen = message.frame_id;
        }

        return;
      }

      attachment->frames.acknowledge(message.frame_id);
      TELAR_DIAGNOSTIC(model_.metrics.frames.merge(attachment->frames.takeCounters()));
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestSnapshot& message) {
    if (auto* attachment = requireClient(clients_, identity).attachmentMut(message.pane_id)) {
      // An editor's client that starts over has no frame: the next one stands alone.
      attachment->editor_seen = 0;
      attachment->editor_sent = 0;
      attachment->frames.requestSnapshot();
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const SetPaneViewport& message) {
    if (auto* attachment = requireClient(clients_, identity).attachmentMut(message.pane_id)) {
      // At or past the bottom the view follows the output, as before any scroll; a row
      // above it stays put while output grows.
      std::uint32_t bottom = 0;

      if (const auto pane = asTerminal(model_.panes.find(message.pane_id))) {
        // The terminal's own count: the screen is captured when a frame goes out, and output read
        // since may have grown the scrollback past the row asked for.
        const auto total = static_cast<std::uint32_t>(std::min<std::size_t>(pane->body.terminal.totalRows(), std::numeric_limits<std::uint32_t>::max()));

        bottom = total - std::min<std::uint32_t>(total, pane->body.terminal.screen().rows);
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
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryMonitor& message) {
    monitor_.query(identity, message, Clock::now());
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestProcessSignal& message) {
    monitor_.act({
        .client = identity,
        .request_id = message.request_id,
        .process = message.process,
        .signal = message.signal,
        .peer = requireClient(clients_, identity).peer_identity,
    });
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestProcessPriority& message) {
    monitor_.act({
        .client = identity,
        .request_id = message.request_id,
        .process = message.process,
        .nice = message.nice,
        .peer = requireClient(clients_, identity).peer_identity,
    });
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
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const DeleteHistoryCommand& message) {
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
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const QueryHistoryWorkspaces& message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const ConfigureGraphics& message) {
    auto& client = requireClient(clients_, identity);

    client.shared_graphics = message.shared;
    for (auto& attachment : client.attachments.viewMut()) {
      attachment.getMut().graphics.configure(message.shared);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const GraphicsCredit& message) {
    if (auto* attachment = requireClient(clients_, identity).attachmentMut(message.pane_id)) {
      attachment->graphics.returnCredit(message.bytes);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t identity, const RequestGraphicsSnapshot& message) {
    if (auto* attachment = requireClient(clients_, identity).attachmentMut(message.pane_id)) {
      attachment->graphics.requestSnapshot();
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::handle(std::uint64_t /*identity*/, const RuntimeStop& /*message*/) {
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
    monitor_.collect([&](std::uint64_t identity, const auto& message) {
      if (auto* client = clients_.find(identity)) {
        client->connection.send(message);
      }
    });

    runtime_clipboard_.collect(clients_);
    workspace_git_.collect(model_, Clock::now());
    shell_git_.collect([&](const ShellGitResult& result) {
      auto pane = asTerminal(findPane(model_.panes, {.id = result.pane, .generation = result.generation}));
      if (pane && !pane->body.shell_state.remote && !(pane->core.git == result.summary)) {
        pane.getMut().core.git = result.summary;
        ++pane.getMut().core.git_revision;
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

    // A reply the wire refuses fails its request alone; a client that cannot take even that is dropped.
    try {
      if (result.spec) {
        client->connection.send(CommandSpec{.request_id = result.request, .command = result.command, .state = result.spec_state, .digest = result.digest, .source = result.source, .expansion = result.expansion});
        return;
      }

      ds::Vec<CompletionWord, ConcurrentMemory> words{memory_};

      words.reserve(result.words.size());
      for (const auto& word : result.words) {
        words.push({.text = word.text.view(), .description = word.description.view()});
      }

      client->connection.send(CompletionWords{.request_id = result.request, .truncated = result.truncated, .words = words.view()});
    } catch (const EncodingError& error) {
      if (!client->connection.trySend(RequestFailed{.request_id = result.request, .code = FailureCode::internal, .message = error.what()})) {
        dropClient(result.client);
      }
    } catch (...) {
      if (!client->connection.trySend(RequestFailed{.request_id = result.request, .code = FailureCode::resource_limit, .message = "Runtime memory or capacity limit reached"})) {
        dropClient(result.client);
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::followMoves(std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) noexcept {
    std::size_t count = 0;

    try {
      count = file_moves_.answered(client_id, payload, request_tag == ClientTag::undo_file_changes);
    } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a move no editor could be told of leaves its buffer where the file was, as a move made outside telar does
    }

    if (count == 0) {
      return;
    }

    for (auto* stored : model_.panes.items()) {
      if (const auto editor = asNvim(stored)) {
        panes_.followMoves(*editor, file_moves_, count);
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::deliverBackgroundReply(std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) {
    if (request_tag == ClientTag::import_history) {
      return;
    }

    // Before the client is looked for: the files moved whether or not it is still here.
    if ((request_tag == ClientTag::change_files || request_tag == ClientTag::undo_file_changes) && file_moves_.waiting()) {
      followMoves(client_id, request_tag, payload);
    }

    if (request_tag == ClientTag::report_agent_command) {
      if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
        limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed commands", .route = "history"});
      }

      return;
    }

    auto* client = clients_.find(client_id);
    if (client == nullptr || client->connection.flags().closing) {
      return;
    }

    try {
      if (payload.front() == static_cast<Byte>(ServerTag::editor_opened)) {
        deliverEditorReply(model_.panes, *client, payload);
      } else {
        const auto tag = static_cast<ServerTag>(payload.front());
        if (tag == ServerTag::history_results || tag == ServerTag::history_output || tag == ServerTag::history_stats_result || tag == ServerTag::history_workspaces || tag == ServerTag::command_suggestion) {
          client->connection.trySendPayload(payload);
        } else {
          client->connection.sendPayload(payload);
        }

        if (client->role == ClientRole::control && isHistoryRequest(request_tag)) {
          client->connection.flagsMut().closing = true;
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
    constexpr std::size_t decode_scratch_bytes = 256;
    ds::Array<Byte, decode_scratch_bytes> scratch{};
    DecodeStorage storage{scratch.viewMut()};
    auto reply = Codec::decode<EditorOpened>(payload, storage);
    const auto* source = livePane(panes, {.id = client.editor_source, .generation = client.editor_generation});
    const auto* target = livePane(panes, {.id = reply.pane_id, .generation = reply.pane_generation});
    if (source == nullptr ||
        (reply.outcome == EditorOutcome::opened && (target == nullptr || target->location.workspace.id != source->location.workspace.id || target->location.tab_id != source->location.tab_id))) {
      reply.outcome = EditorOutcome::failed;
    }

    client.editor_source = 0;
    client.connection.send(reply);
  }

  // What a terminal needs between events: its clipboard requests advanced, its shell observed
  // when it changes the terminal without printing, its repository followed and its exit recorded.
  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::refreshPane(PaneRef<TerminalBody> pane, Clock::time_point now, bool poll_panes) {
    try {
      if (ClipboardService::advance(clients_, pane, now) && !pane.core.output_closed) {
        panes_.flushInput(pane);
        media_.updateReadInterest(pane);
      }
    } catch (const std::exception&) {
      panes_.failOutput(pane);
    }

    // A program can change the terminal without printing, as `read -s` does; one that
    // prints is observed as it reads.
    if (poll_panes && !pane.core.exit_status && pane.body.shell_state.phase != ShellPhase::prompt) {
      pane.body.observeShell();
    }

    followRepository(pane, shell_git_);
    if (pane.core.exit_status && pane.core.output_closed && !pane.core.exit_observed) {
      pane.body.observer->shellExit(*pane.core.exitCode());
      pane.core.exit_observed = true;
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::refreshPane(PaneRef<ExplorerBody> /*pane*/, Clock::time_point /*now*/, bool /*poll_panes*/) noexcept {}

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::refreshPane(PaneRef<NvimBody> pane, Clock::time_point /*now*/, bool /*poll_panes*/) {
    relay(pane);
    // What the editor queued outside a request of a client, as its theme is, is written now.
    if (pane.body.hasInput()) {
      panes_.flushEditor(pane);
    }

    const auto& screen = pane.body.editor.screen();

    // The pane's directory is the one Neovim last said it works in.
    if (pane.body.directory_at != screen.directoryAt()) {
      pane.body.directory_at = screen.directoryAt();
      if (!screen.directory().empty() && pane.core.cwd.view() != screen.directory()) {
        pane.core.cwd.assign(screen.directory());
        ++pane.core.cwd_revision;
      }
    }

    // A Neovim the editor could not attach to has nothing to show: its pane ends.
    if (pane.body.editor.state() == NvimState::failed && !pane.core.close_requested) {
      panes_.failEditor(pane);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::followRepository(PaneRef<TerminalBody> pane, ShellGitService& shell_git) {
    // A remote shell's repository is not on this host: forget the local one it left.
    if (pane.body.shell_state.remote && (pane.core.git.repository || !pane.core.git_directory.view().empty())) {
      pane.core.git = {};
      pane.core.git_directory.assign(std::string_view{});
      ++pane.core.git_revision;
    }

    // Back at the prompt after a command, or in another directory: read its repository.
    if (!pane.body.shell_zones || pane.body.shell_state.remote || pane.body.shell_state.phase != ShellPhase::prompt) {
      return;
    }

    // The zones are read and the repository's directory written apart, as Rust splits a borrow of a pane.
    const auto& zones = *pane.body.shell_zones;
    auto& git_directory = pane.core.git_directory;
    const auto directory = zones.directory();
    if (pane.core.git_commands != pane.body.shell_state.commands || git_directory.view() != directory) {
      pane.core.git_commands = pane.body.shell_state.commands;
      git_directory.assign(directory);
      shell_git.request(pane.core.id, pane.core.generation, directory);
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::refreshServices(Clock::time_point now) {
    try {
      observations_.refresh(model_, agents_);
      answerDeferredReports();
      agents_.refresh(model_, panes_, clients_, client_layouts_);
      agent_files_.tick(agents_, now);
      descriptions_.tick(agents_);
      worktree_detection_.tick(model_);
    } catch (const std::bad_alloc&) { // NOLINT(bugprone-empty-catch): a service that runs out of memory tries again on the next wake
    } catch (const RequestError&) {   // NOLINT(bugprone-empty-catch): a service that runs out of capacity tries again on the next wake
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::addMonitorRoots(MonitorWork& work) const {
    // Each pane's shell, and whether an agent runs in the pane now.
    for (const auto* pane : model_.panes.items()) {
      if (work.root_count == work.roots.size()) {
        break;
      }

      if (pane == nullptr || pane->exit_status || pane->process_id <= 0) {
        continue;
      }

      const auto* agent = agents_.find(pane->id, pane->generation);
      const auto working = agent != nullptr && agent->status != AgentStatus::done && agent->status != AgentStatus::failed;

      work.roots.atMut(work.root_count++) = {.process = pane->process_id, .pane_id = pane->id, .agent = working};
    }

    // The windows and commands connected to the runtime are telar's processes too.
    for (const auto* client : clients_.items()) {
      if (work.client_count == work.clients.size()) {
        break;
      }

      if (client != nullptr && client->peer_identity) {
        work.clients.atMut(work.client_count++) = client->peer_identity->pid;
      }
    }
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::chrono::nanoseconds Runtime<Poller, Background>::serveClient(std::size_t slot, Clock::time_point now) {
    auto timeout = std::chrono::nanoseconds::max();
    const auto* listed = clients_.items()[slot];
    if (listed == nullptr) {
      return timeout;
    }

    const auto identity = listed->id;

    if (listed->connection.flags().closing && !listed->connection.hasOutput()) {
      dropClient(identity);
      return timeout;
    }

    try {
      if (listed->connection.flags().closing) {
        auto& closing = requireClient(clients_, identity);

        closing.connection.write(ResponseProjection{memory_, model_});
        updateWriteInterest(poller_, closing);
        return timeout;
      }

      if (listed->connection.flags().buffered_requests && !listed->connection.flags().read_paused) {
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

    return timeout;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::chrono::nanoseconds Runtime<Poller, Background>::publish(Clock::time_point now) {
    TELAR_TRACE("runtime.publish");
    admissions_.expire(now);
    runtime_clipboard_.expire(clients_, now);
    media_.collect(model_, clients_, panes_);
    // The longest a wake waits, and how soon it comes again while executions run.
    constexpr auto idle_wait = std::chrono::milliseconds{100};
    constexpr auto execution_wait = std::chrono::milliseconds{10};
    std::chrono::nanoseconds timeout = idle_wait;
    // Panes are polled for what changes without a sound on a beat, not on every wake: output
    // from any pane wakes the loop, and asking each of them would cost syscalls per pane.
    const bool poll_panes = now >= next_pane_poll_;
    if (poll_panes) {
      next_pane_poll_ = now + pane_poll_interval;
    }

    timeout = std::min(timeout, std::chrono::duration_cast<std::chrono::nanoseconds>(next_pane_poll_ - now));
    const bool reap = std::exchange(children_exited_, false) || poll_panes;

    for (auto* stored : model_.panes.items()) {
      if (stored == nullptr) {
        continue;
      }

      // SIGCHLD says a child exited; a closed output usually means it did. The beat catches a
      // child whose signal went to no one, such as one reaped while a test drives the loop.
      if (!stored->exit_status && (reap || stored->output_closed)) {
        stored->exit_status = reapProcess(*stored);
        model_.pane_revision += static_cast<std::uint64_t>(stored->exit_status.hasValue());
      }

      visitPaneAs(*stored, [&](auto kind) {
        refreshPane(kind, now, poll_panes);
      });
    }

    if (executions_.refresh(model_)) {
      timeout = std::min(timeout, std::chrono::nanoseconds{execution_wait});
    }

    refreshServices(now);

    Worktrees::refresh(model_);
    worktrees_.observe(model_, background_);
    workspaces_.collectExited(model_, panes_, clients_);
    timeout = std::min(timeout, session_.tick(model_, client_layouts_, agents_, now));
    timeout = std::min(timeout, metrics_.tick(now));
    timeout = std::min(timeout, monitor_.tick(now, [this](MonitorWork& work) {
      addMonitorRoots(work);
    }));

    timeout = std::min(timeout, workspace_git_.tick(model_, now));
    deliverQueued();

    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {
      timeout = std::min(timeout, serveClient(slot, now));
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
      panes_.release(model_, clients_, {.client = identity, .pane = *result.detach_pane});
    }

    return result.timeout;
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  void Runtime<Poller, Background>::updateWriteInterest(Poller& poller, ClientSession& client) {
    const bool enabled = client.connection.hasOutput();
    if (enabled != client.connection.flags().write_interest) {
      poller.writeInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), enabled);
      client.connection.flagsMut().write_interest = enabled;
    }

    const bool readable = !client.connection.flags().read_paused;
    if (readable != client.connection.flags().read_interest) {
      poller.readInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), readable);
      client.connection.flagsMut().read_interest = readable;
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
        if (!client->connection.flags().closing) {
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
      } catch (...) { // NOLINT(bugprone-empty-catch): the goodbye is best effort; the client is dropped either way
      }

      dropClient(identity);
    }

    for (auto* pane : model_.panes.items()) { // NOLINT(misc-const-correctness): the pane's session is finished through its shared observer, a mutation tbc sees through the pane
      if (pane != nullptr) {
        signalProcess(*pane, SIGTERM);
        if (const auto terminal = asTerminal(pane)) {
          terminal->body.observer->finishSession();
        }
      }
    }

    observations_.finish(model_);
    media_.finish(model_);
  }

  template <EventLoop Poller, typename Background>
    requires BackgroundExecutor<Background, ConcurrentMemory>
  std::string_view Runtime<Poller, Background>::runtimePath() {
    const char* path = std::getenv("PATH"); // NOLINT(concurrency-mt-unsafe): POSIX has no thread-safe read of the environment

    return path == nullptr ? std::string_view{"/usr/bin:/bin"} : std::string_view{path};
  }

  template class Runtime<NativeEventLoop<ConcurrentMemory>, RuntimeBackground>;

}
