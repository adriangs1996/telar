#pragma once

#include "../agents/prompt_budget.hpp"
#include "../agents/screen_observation.hpp"
#include "../agents/snapshot.hpp"
#include "../model/client_layouts.hpp"
#include "../platform/process_inspector.hpp"
#include "../platform/process_probe.hpp"
#include "description_queue.hpp"
#include "pane_service.hpp"
#include <termios.h>

namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class AgentService {
public:
  explicit AgentService(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, const ClientLayouts<Memory> &layouts)
      : model_(model),
        panes_(panes),
        layouts_(layouts),
        agents_(memory),
        descriptions_(agents_) {}

  void enableDescriptions(bool enabled) noexcept {
    descriptions_.enable(enabled);
  }

  void observeInput(const Pane<Memory> &pane, std::span<const Byte> bytes) {
    if (descriptions_.enabled()) {
      if (auto *agent = agents_.find(pane.id, pane.generation)) {
        agent->observeInput(bytes);
      }
    }
  }

  std::optional<DescriptionRequest> nextDescription() {
    return descriptions_.nextDescription();
  }

  std::optional<HistorySessionTitle> completeDescription(const DescriptionResult &result) {
    return descriptions_.completeDescription(result);
  }

  void report(ClientSession<Memory> &client, const ReportAgent &request) {
    auto &pane = authorize(client, request.pane_id, request.pane_generation, request.provider);
    auto *existing = agents_.find(pane.id, pane.generation);
    if (existing == nullptr && request.state == AgentReportState::continuing) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    auto &agent = existing != nullptr ? *existing : ensure(pane);
    const auto previous = agent.status;
    const auto previous_watch = agent.file_watch.revision;
    if (agent.report(request, client.deferred_report.reportTime())) {
      projected(agent);
      if ((agent.status == AgentStatus::done && previous == AgentStatus::working) || (agent.status == AgentStatus::blocked && previous != AgentStatus::blocked)) {
        sound(agent);
      }
    }

    if (agent.file_watch.revision != previous_watch) {
      agent.file_watch.revision = ++session_watch_revision_;
      has_session_files_ = true;
    }

    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  void reportSession(ClientSession<Memory> &client, const ReportAgentSession &request) {
    auto &pane = require(request.pane_id, request.pane_generation);
    ensure(pane).setSession(request.session);
    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  void reportTitle(ClientSession<Memory> &client, const ReportAgentTitle &request) {
    auto &pane = authorize(client, request.pane_id, request.pane_generation, request.provider);
    auto &agent = ensure(pane);
    agent.evidence.claim(request.provider);
    if (agent.reportTitle(request.title)) {
      agents_.changed();
    }
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  std::optional<SessionFileRequest> nextSessionFile(std::chrono::steady_clock::time_point now) const {
    if (!has_session_files_) {
      return std::nullopt;
    }

    const Agent *selected = nullptr;
    for (const auto &agent : agents_.records()) {
      const auto &watch = agent->file_watch;
      if (watch.path.view().empty() || now - watch.checked_at < std::chrono::seconds{1}) {
        continue;
      }
      if (selected == nullptr || watch.checked_at < selected->file_watch.checked_at) {
        selected = agent.get();
      }
    }

    return selected == nullptr ? std::nullopt : std::optional{SessionFileRequest{selected->pane, selected->generation, selected->file_watch}};
  }

  void completeSessionFile(const SessionFileResult &result, std::chrono::steady_clock::time_point now) {
    auto *agent = agents_.find(result.request.pane, result.request.generation);
    if (agent == nullptr) {
      return;
    }

    auto &watch = agent->file_watch;
    const auto &requested = result.request.watch;
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
      } catch (const std::exception &) {
      }
    }
  }

  bool reportProgress(ClientSession<Memory> &client, const ReportAgentProgress &request) {
    auto &pane = authorize(client, request.pane_id, request.pane_generation, request.provider);
    auto &agent = ensure(pane);
    agent.evidence.claim(request.provider);
    const bool applied = agent.progress.apply(request);

    if (!request.cwd.empty()) {
      const auto *worktree = model_.worktrees.containing(request.cwd);
      if (worktree != nullptr) {
        agent.worktree = worktree->id;
      } else if (!request.work_tree_path.empty()) {
        const auto branch = request.work_tree_branch.empty() ? request.work_tree_path.substr(request.work_tree_path.rfind('/') + 1) : request.work_tree_branch;
        const auto result = model_.worktrees.registerEntry(RegisterWorktree{.source = model_.worktrees.sourceFor(pane.location.workspace.id),
                                                                            .created_by = pane.id,
                                                                            .origin = WorktreeOrigin::external,
                                                                            .path = request.work_tree_path,
                                                                            .branch = branch});
        agent.worktree = result.worktree;
        ++model_.workspace_revision;
      } else {
        agent.worktree = 0;
      }
    }

    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
    return applied;
  }

  Pane<Memory> &validateCommand(ClientSession<Memory> &client, const ReportAgentCommand &request) {
    return authorize(client, request.pane_id, request.pane_generation, model_.manifests.named(request.provider));
  }

  void sendText(ClientSession<Memory> &client, const SendPaneText &request) {
    auto &pane = panes_.requireGeneration(request.pane_id, request.pane_generation);
    if (pane.exit_status || pane.output_closed) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }
    if (focused(pane.id)) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }
    if (request.mode == PaneTextMode::prompt && blocked(pane)) {
      throw RequestError{FailureCode::agent_blocked, "Agent is waiting for a decision"};
    }
    std::array<char, 192> prefix{};
    std::size_t length = 0;
    const auto *sender = request.sender ? model_.panes.find(*request.sender) : nullptr;
    if (request.mode == PaneTextMode::prompt && sender != nullptr) {
      if (!prompt_budget_.spend(sender->id, pane.id, std::chrono::steady_clock::now())) {
        throw RequestError{FailureCode::prompt_rate_limited, "Prompt budget for this pane is spent; wait for its answer"};
      }
      std::string_view name = "a telar pane";
      if (const auto *workspace = model_.workspaces.find(sender->location.workspace.id)) {
        name = workspace->displayName();
      }
      for (const auto *worktree : model_.worktrees.items()) {
        if (worktree != nullptr && worktree->workspace == sender->location.workspace.id) {
          name = worktree->branch.view();
          break;
        }
      }
      name = utf8Prefix(name, 64);
      length = static_cast<std::size_t>(std::snprintf(prefix.data(), prefix.size(), "[telar: from %.*s, pane %llu] ", static_cast<int>(name.size()), name.data(), static_cast<unsigned long long>(sender->id)));
    }
    panes_.sendText(client, request, {prefix.data(), length}, [this](const Pane<Memory> &target, std::span<const Byte> bytes) { observeInput(target, bytes); });
  }

  void acknowledge(const AcknowledgeAgent &request) noexcept {
    if (auto *agent = agents_.find(request.pane_id, request.pane_generation); agent != nullptr && agent->status == AgentStatus::done) {
      agent->acknowledged = true;
      if (agent->project(wallMilliseconds())) {
        projected(*agent);
      }
    }
  }

  void interrupt(ClientSession<Memory> &client, const InterruptAgent &request) {
    auto &pane = panes_.requireGeneration(request.pane_id, request.pane_generation);
    if (pane.exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }
    if (focused(pane.id)) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }
    auto *agent = agents_.find(pane.id, pane.generation);
    const auto now = std::chrono::steady_clock::now();
    if (agent != nullptr && agent->interrupt_at && now - *agent->interrupt_at < std::chrono::seconds{2}) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (agent == nullptr || agent->status != AgentStatus::working) {
      throw RequestError{FailureCode::agent_not_working, "Agent is not working"};
    }
    const auto *manifest = model_.manifests.find(agent->provider);
    if (manifest == nullptr || manifest->interrupt == AgentInterruptKey::none) {
      throw RequestError{FailureCode::interrupt_unsupported, "Agent declares no interrupt key"};
    }

    std::array<Byte, 128> encoded;
    const bool control_c = manifest->interrupt == AgentInterruptKey::control_c;
    const auto bytes = pane.terminal.encodeKey(control_c ? GHOSTTY_KEY_C : GHOSTTY_KEY_ESCAPE, control_c ? GHOSTTY_MODS_CTRL : 0, encoded);
    const auto repeats = manifest->interrupt == AgentInterruptKey::escape_twice ? 2 : 1;
    if (panes_.admitInput(pane, bytes.size() * repeats)) {
      for (int index = 0; index < repeats; ++index) {
        pane.enqueueInput(bytes);
      }
      panes_.flushInput(pane);
    }
    agent->report(ReportAgent{.state = AgentReportState::settling,
                              .event = "Interrupted by telar"});
    agent->interrupt_at = now;
    agent->interrupt_revision = pane.terminal.contentRevision();
    projected(*agent);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  bool focused(std::uint64_t pane) const noexcept {
    for (const auto *client : model_.clients.items()) {
      if (client != nullptr && client->role == ClientRole::interactive && !client->connection.closing && layouts_.focusedPane(client->identity) == pane) {
        return true;
      }
    }

    return false;
  }

  bool blocked(const Pane<Memory> &pane) const noexcept {
    const auto *agent = agents_.find(pane.id, pane.generation);
    return agent != nullptr && agent->status == AgentStatus::blocked;
  }

  void query(ClientSession<Memory> &client) {
    snapshots_.publish(client, model_, agents_);
  }

  std::uint64_t revision() const noexcept {
    return agents_.revision();
  }

  const Agent *find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    return agents_.find(pane, generation);
  }

  void observeProcess(Pane<Memory> &pane, std::optional<ProcessIdentity> identity, AgentProvider provider) {
    auto *agent = agents_.find(pane.id, pane.generation);
    if (agent != nullptr && agent->process_identity && provider == AgentProvider::unknown) {
      agents_.removeIf([&](const Agent &record) { return record.pane == pane.id && record.generation == pane.generation; });
      return;
    }

    observeProcess(pane, agent, identity, provider);
  }

  void observeProcess(Pane<Memory> &pane, const ProcessProbeResult &observation) {
    observeProcess(pane, observation.identity, observation.provider);
    auto *agent = agents_.find(pane.id, pane.generation);
    if (agent == nullptr) {
      return;
    }
    if (observation.shell_foreground) {
      agents_.removeIf([&](const Agent &record) { return record.pane == pane.id && record.generation == pane.generation; });
      return;
    }

    if (agent->setProcessContext(observation.session_host, observation.hooks_installed, observation.agent_identity)) {
      if (agent->project(wallMilliseconds())) {
        projected(*agent);
      } else {
        agents_.changed();
      }
    }
  }

  void observeScreen(Pane<Memory> &pane, const AgentSignal &signal, ObservationTime time) {
    auto *agent = agents_.find(pane.id, pane.generation);
    if (agent == nullptr) {
      return;
    }

    const auto previous = agent->status;
    if (agent->observeScreen(signal, time)) {
      projected(*agent);
      if ((agent->status == AgentStatus::done && previous == AgentStatus::working) || (agent->status == AgentStatus::blocked && previous != AgentStatus::blocked)) {
        sound(*agent);
      }
    }
  }

  void refresh(std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now()) {
    agents_.removeIf([&](const Agent &agent) { const auto *pane = model_.panes.find(agent.pane); return pane == nullptr || pane->generation != agent.generation || (!agent.evidence.choose(wallMilliseconds()) && agent.observed_at != 0); });
    for (auto *pane : model_.panes.items()) {
      if (pane == nullptr || pane->exit_status) {
        continue;
      }
      auto *agent = agents_.find(pane->id, pane->generation);
      if (agent == nullptr) {
        continue;
      }
      if (agent->cwd_revision != pane->cwd_revision || agent->title_revision != pane->terminal.effects.title_revision) {
        agent->cwd_revision = pane->cwd_revision;
        agent->title_revision = pane->terminal.effects.title_revision;
        agents_.changed();
      }

      if (agent->interrupt_at) {
        settleInterrupt(*pane, *agent, now);
      }
      const auto current_time = wallMilliseconds();
      agent->evidence.expire(current_time);
      if (!agent->evidence.report) {
        agent->interrupt_at.reset();
        agent->interrupt_idle_at.reset();
      }

      if (agent->project(current_time)) {
        projected(*agent);
      }
    }
  }

private:
  Agent &ensure(Pane<Memory> &pane) {
    auto &agent = agents_.ensure(pane.id, pane.generation);
    agent.session_id = pane.history_session;
    return agent;
  }

  void projected(Agent &agent) noexcept {
    descriptions_.project(agent);

    agent.sequence = ++sequence_;
    agents_.changed();
  }

  Agent *observeProcess(Pane<Memory> &pane, Agent *agent, std::optional<ProcessIdentity> identity, AgentProvider provider) {
    if (!identity || provider == AgentProvider::unknown) {
      return agent;
    }

    if (agent == nullptr) {
      if (agents_.records().size() == AgentRegistry<Memory>::capacity) {
        return nullptr;
      }

      agent = &ensure(pane);
    }

    if (agent->observeProcess(*identity, provider)) {
      projected(*agent);
    }

    if (pane.restored_agent) {
      const auto &restored = *pane.restored_agent;
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

    return agent;
  }

  void settleInterrupt(Pane<Memory> &pane, Agent &agent, std::chrono::steady_clock::time_point now) {
    bool settled = false;
    if (hasIdleScreen(agent.provider)) {
      if (pane.terminal.contentRevision() <= agent.interrupt_revision || !pane.terminal.outputSettled()) {
        return;
      }
      pane.terminal.refresh();
      const auto observation = AgentScreenReader{pane.terminal}.observe(agent.provider);
      if (observation.restored_draft && !agent.interrupt_draft_cleared && !focused(pane.id)) {
        std::array<Byte, 128> encoded;
        const auto bytes = pane.terminal.encodeKey(GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL, encoded);
        if (panes_.admitInput(pane, bytes.size())) {
          pane.enqueueInput(bytes);
          panes_.flushInput(pane);
        }
        agent.interrupt_draft_cleared = true;
        agent.interrupt_at = now;
        agent.interrupt_idle_at.reset();
        agent.interrupt_revision = pane.terminal.contentRevision();
        return;
      }
      if (observation.status != AgentStatus::ready || observation.restored_draft) {
        agent.interrupt_idle_at.reset();
        return;
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

      if (agent.project(wallMilliseconds())) {
        projected(agent);
      }
    }
  }

  Pane<Memory> &require(std::uint64_t identity, std::uint64_t generation) const {
    auto &pane = panes_.requireGeneration(identity, generation);
    if (generation == 0 || pane.exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    return pane;
  }

  Pane<Memory> &authorize(ClientSession<Memory> &client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider) {
    TELAR_TRACE("agents.authorize");
    auto &pane = require(pane_id, generation);
    if (provider == AgentProvider::unknown) {
      return pane;
    }

    if (client.verified_pane != pane.id || client.verified_generation != pane.generation) {
      throw RequestError{FailureCode::foreign_process, "The report does not come from this pane's agent"};
    }

    if (const auto *agent = agents_.find(pane.id, pane.generation); agent != nullptr && !agent->evidence.accepts(provider)) {
      throw RequestError{FailureCode::foreign_process, "The report belongs to another agent"};
    }

    return pane;
  }

  void sound(const Agent &agent) noexcept {
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || !client->subscribed || client->connection.closing) {
        continue;
      }
      try {
        client->connection.trySend(AgentSoundNotification{.pane_id = agent.pane,
                                                          .pane_generation = agent.generation,
                                                          .sound = agent.status == AgentStatus::blocked ? AgentSound::needs_input : AgentSound::ready});
      } catch (...) {
        client->connection.closing = true;
      }
    }
  }

  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
  const ClientLayouts<Memory> &layouts_;
  AgentRegistry<Memory> agents_;
  DescriptionQueue<Memory> descriptions_;
  AgentSnapshotBuilder<Memory> snapshots_;
  PromptBudget prompt_budget_;
  std::uint64_t sequence_ = 0;
  std::uint64_t session_watch_revision_ = 0;
  bool has_session_files_ = false;
};

}
