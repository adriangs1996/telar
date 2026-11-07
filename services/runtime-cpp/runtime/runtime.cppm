module;
#include "telar_platform/trace_macro.hpp"
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <cstdint>
#include <cstring>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <sys/types.h>
#include <cerrno>
#include <unistd.h>
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/stat.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <new>
#include <termios.h>


#include <poll.h>

#include <dirent.h>
#if (TELAR_DIAGNOSTICS)
#include <pthread.h>
#endif
#if (TELAR_DIAGNOSTICS) && (defined(__APPLE__))
#include <mach/mach.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#include <sys/file.h>
#include <sys/un.h>
#include <sqlite3.h>

export module telar.runtime.runtime.runtime;

import std;

export import telar.runtime.agents.screen_inference;
export import telar.runtime.agents.snapshot;
export import telar.runtime.model.client_layouts;
export import telar.runtime.platform.process_probe;
export import telar.runtime.runtime.media_service;
export import telar.runtime.runtime.execution_service;


export import telar.client;


export import telar.runtime.agents.description_generator;
export import telar.runtime.persistence.session_store;
export import telar.config;


export import telar.runtime.plugins.service;
export import telar.runtime.runtime.client_control;


export import telar.runtime.platform.launch_program;
export import telar.runtime.worktrees.git_probe;


export import telar.runtime.diagnostics.runtime_telemetry;
export import telar.runtime.exchange_capture.pipeline;
export import telar.runtime.exchange_capture.exchange;
export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.suggestions.engine;

export import telar.runtime.runtime.background_executor;
export import telar.runtime.runtime.delivery.client_delivery;


export import telar.base.editors;
export import telar.base.text;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: runtime/agent_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class AgentService {
public:
  inline explicit AgentService(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, const ClientLayouts<Memory> &layouts)
      : model_(model),
        panes_(panes),
        layouts_(layouts),
        agents_(memory),
        descriptions_(agents_) {}

  inline void enableDescriptions(bool enabled) noexcept {
    descriptions_.enable(enabled);
  }

  inline void observeInput(const Pane<Memory> &pane, std::span<const Byte> bytes) {
    if (descriptions_.enabled()) {
      if (auto *agent = agents_.find(pane.id, pane.generation)) {
        agent->observeInput(bytes);
      }
    }
  }

  inline std::optional<DescriptionRequest> nextDescription() {
    return descriptions_.nextDescription();
  }

  inline std::optional<HistorySessionTitle> completeDescription(const DescriptionResult &result) {
    return descriptions_.completeDescription(result);
  }

  inline void report(ClientSession<Memory> &client, const ReportAgent &request) {
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

  inline void reportSession(ClientSession<Memory> &client, const ReportAgentSession &request) {
    auto &pane = require(request.pane_id, request.pane_generation);
    ensure(pane).setSession(request.session);
    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline void reportTitle(ClientSession<Memory> &client, const ReportAgentTitle &request) {
    auto &pane = authorize(client, request.pane_id, request.pane_generation, request.provider);
    auto &agent = ensure(pane);
    agent.evidence.claim(request.provider);
    if (agent.reportTitle(request.title)) {
      agents_.changed();
    }
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline std::optional<SessionFileRequest> nextSessionFile(std::chrono::steady_clock::time_point now) const {
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

  inline void completeSessionFile(const SessionFileResult &result, std::chrono::steady_clock::time_point now) {
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

  inline bool reportProgress(ClientSession<Memory> &client, const ReportAgentProgress &request) {
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

  inline Pane<Memory> &validateCommand(ClientSession<Memory> &client, const ReportAgentCommand &request) {
    return authorize(client, request.pane_id, request.pane_generation, model_.manifests.named(request.provider));
  }

  inline void sendText(ClientSession<Memory> &client, const SendPaneText &request) {
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

  inline void acknowledge(const AcknowledgeAgent &request) noexcept {
    if (auto *agent = agents_.find(request.pane_id, request.pane_generation); agent != nullptr && agent->status == AgentStatus::done) {
      agent->acknowledged = true;
      if (agent->project(wallMilliseconds())) {
        projected(*agent);
      }
    }
  }

  inline void interrupt(ClientSession<Memory> &client, const InterruptAgent &request) {
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

  inline bool focused(std::uint64_t pane) const noexcept {
    for (const auto *client : model_.clients.items()) {
      if (client != nullptr && client->role == ClientRole::interactive && !client->connection.closing && layouts_.focusedPane(client->identity) == pane) {
        return true;
      }
    }

    return false;
  }

  inline bool blocked(const Pane<Memory> &pane) const noexcept {
    const auto *agent = agents_.find(pane.id, pane.generation);
    return agent != nullptr && agent->status == AgentStatus::blocked;
  }

  inline void query(ClientSession<Memory> &client) {
    snapshots_.publish(client, model_, agents_);
  }

  inline std::uint64_t revision() const noexcept {
    return agents_.revision();
  }

  inline const Agent *find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    return agents_.find(pane, generation);
  }

  inline void observeProcess(Pane<Memory> &pane, std::optional<ProcessIdentity> identity, AgentProvider provider) {
    auto *agent = agents_.find(pane.id, pane.generation);
    if (agent != nullptr && agent->process_identity && provider == AgentProvider::unknown) {
      agents_.removeIf([&](const Agent &record) { return record.pane == pane.id && record.generation == pane.generation; });
      return;
    }

    observeProcess(pane, agent, identity, provider);
  }

  inline void observeProcess(Pane<Memory> &pane, const ProcessProbeResult &observation) {
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

  inline void observeScreen(Pane<Memory> &pane, const AgentSignal &signal, ObservationTime time) {
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

  inline void refresh(std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now()) {
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
  inline Agent &ensure(Pane<Memory> &pane) {
    auto &agent = agents_.ensure(pane.id, pane.generation);
    agent.session_id = pane.history_session;
    return agent;
  }

  inline void projected(Agent &agent) noexcept {
    descriptions_.project(agent);

    agent.sequence = ++sequence_;
    agents_.changed();
  }

  inline Agent *observeProcess(Pane<Memory> &pane, Agent *agent, std::optional<ProcessIdentity> identity, AgentProvider provider) {
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

  inline void settleInterrupt(Pane<Memory> &pane, Agent &agent, std::chrono::steady_clock::time_point now) {
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

  inline Pane<Memory> &require(std::uint64_t identity, std::uint64_t generation) const {
    auto &pane = panes_.requireGeneration(identity, generation);
    if (generation == 0 || pane.exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    return pane;
  }

  inline Pane<Memory> &authorize(ClientSession<Memory> &client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider) {
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

  inline void sound(const Agent &agent) noexcept {
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
}

// Interface: runtime/launch_directory.cppm
export {
namespace telar::runtime {

using LaunchDirectoryScope = std::variant<std::monostate, WorkspaceLocation, TabLocation>;

template <Allocator Memory>
Launch resolveLaunchDirectory(const RuntimeModel<Memory> &model, const ClientSession<Memory> &client, Launch launch, LaunchDirectoryScope scope = {}) {
  if (launch.cwd_source == 0) {
    return launch;
  }

  const auto *pane = model.panes.find(launch.cwd_source);
  if (client.attachment(launch.cwd_source) == nullptr || pane == nullptr || pane->close_requested || pane->exit_status) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }

  const auto *workspace = std::get_if<WorkspaceLocation>(&scope);
  const auto *tab = std::get_if<TabLocation>(&scope);
  if (tab != nullptr) {
    workspace = &tab->workspace;
  }
  if (workspace != nullptr && (workspace->kind != pane->location.workspace.kind || workspace->id != pane->location.workspace.id)) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }
  if (tab != nullptr && tab->tab_id != pane->location.tab_id) {
    throw RequestError{FailureCode::invalid_request, "cwd source pane is unavailable"};
  }

  launch.cwd = pane->cwd;
  launch.cwd_source = 0;
  return launch;
}

}
}

// Interface: runtime/options.cppm
export {
namespace telar::runtime {

struct RuntimeOptions {
  std::string_view socket;
  std::string_view cli_executable;
  checkpoint::Options session;
  bool fresh = false;
  bool capture_output = false;
  const AgentManifests *manifests = &builtin_manifests;
  DescriptionOptions descriptions;
  GraphicsLimits graphics;
  control::Policy control_policy{};
};

}
}

// Interface: runtime/plugin_delivery.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class PluginDelivery {
public:
  inline explicit PluginDelivery(ClientControl<Memory> &clients, LimitService<Memory> &limits) noexcept
      : clients_(clients), limits_(limits) {}

  template <plugins::EventSource Source>
  inline void collect(Source &source) {
    source.collect([this](const plugins::EffectBatch &batch) {
      for (const auto &notification : std::span{batch.notifications}.first(batch.count)) {
        publish(notification);
      }
    });
    const auto now = source.metrics();
    reportGrowth(now.dropped_queue, previous_.dropped_queue, {"plugins.tap.queue_depth", "exchanges", plugins::Limits::queue_depth});
    reportGrowth(now.dropped_bytes, previous_.dropped_bytes, {"plugins.tap.max_held_bytes", "bytes", plugins::Limits::held_bytes});
    reportGrowth(now.timeouts, previous_.timeouts, {"plugins.tap.reply_timeout_ms", "ms", std::chrono::duration_cast<std::chrono::milliseconds>(plugins::Limits::reply_deadline).count()});
    reportGrowth(now.disabled, previous_.disabled, {"plugins.tap.restart_limit", "restarts in 10 min", plugins::Limits::restarts});
    previous_ = now;
  }

private:
  inline void publish(const NotificationBody &body) {
    const Notification notification{body};
    std::array<Byte, validation_bytes> validation;
    std::span<Byte> remaining{validation};
    try {
      Codec::encode(notification, remaining);
    } catch (const EncodingError &) {
      return;
    }
    clients_.publish(notification);
  }

  inline void reportGrowth(std::uint64_t current, std::uint64_t previous, const LimitReach &reach) {
    if (current > previous) {
      limits_.report(reach);
    }
  }

  static constexpr std::size_t validation_bytes = 512;
  ClientControl<Memory> &clients_;
  LimitService<Memory> &limits_;
  plugins::TapMetrics previous_;
};

template <Allocator Memory>
PluginDelivery(ClientControl<Memory> &clients, LimitService<Memory> &limits) -> PluginDelivery<Memory>;

}
}

// Interface: runtime/workspace_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorkspaceService {
public:
  inline explicit WorkspaceService(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes)
      : memory_(memory),
        model_(model),
        panes_(panes) {}

  inline Workspace<Memory> &require(WorkspaceLocation location) const {
    auto *workspace = model_.workspaces.find(location.id);
    if (location.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
    }

    return *workspace;
  }

  inline Tab<Memory> &requireTab(TabLocation location) const {
    auto *tab = require(location.workspace).tab(location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    return *tab;
  }

  inline void open(ClientSession<Memory> &client, const OpenPane &request) {
    Pane<Memory> *pane = nullptr;
    bool created = false;

    if (request.target.kind == PaneTarget::Kind::pane) {
      pane = &panes_.require(request.target.id);
      if (pane->close_requested || pane->exit_status) {
        throw RequestError{FailureCode::pane_not_found, "pane not found"};
      }
    } else if (request.target.kind == PaneTarget::Kind::workspace) {
      auto &workspace = require(WorkspaceLocation{.id = request.target.id});
      pane = firstPane(workspace);
    } else {
      if (!request.launch) {
        throw RequestError{FailureCode::invalid_request, "default pane launch is missing"};
      }

      auto launch = resolveLaunchDirectory(model_, client, *request.launch);
      Workspace<Memory> *workspace = nullptr;

      for (auto *candidate : model_.workspaces.items()) {
        if (candidate != nullptr && candidate->path == launch.cwd) {
          workspace = candidate;
          break;
        }
      }

      if (workspace != nullptr) {
        pane = firstPane(*workspace);
        if (pane == nullptr && !workspace->tabs.empty()) {
          pane = &createAt(client, TabLocation{WorkspaceLocation{.id = workspace->id}, workspace->tabs.front().id}, launch, request.size);
          created = true;
        }
      } else {
        pane = &createRoot(client, launch, request.size, {});
        created = true;
      }
    }

    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "workspace has no running pane"};
    }

    panes_.attach(client, *pane, request.size);
    sendOpened(client, request.request_id, *pane, created);
  }

  inline void createWorkspace(ClientSession<Memory> &client, const CreateWorkspace &request) {
    auto launch = resolveLaunchDirectory(model_, client, request.launch);
    if (request.create_cwd && request.launch.cwd_source == 0) {
      createDirectories(launch.cwd);
    }

    auto &pane = createRoot(client, launch, request.size, request.name, true);
    sendOpened(client, request.request_id, pane, true, GenerationField::omitted);
  }

  inline void createTab(ClientSession<Memory> &client, const CreateTab &request) {
    auto &workspace = require(request.workspace);
    requireGeometry(client, workspace);
    const auto launch = resolveLaunchDirectory(model_, client, request.launch, request.workspace);
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity();
    workspace.tabs.emplace_back(memory_, tab_id, request.label);

    try {
      auto &pane = createAt(client, TabLocation{request.workspace, tab_id}, launch, request.size);
      ++model_.next_tab_id;
      client.connection.send(TabCreated{
          .request_id = request.request_id,
          .location = pane.location,
          .position = static_cast<std::uint16_t>(workspace.tabs.size() - 1),
          .label = workspace.tabs.back().label,
          .root_pane_id = pane.id,
          .pane_generation = pane.generation,
      });
    } catch (...) {
      if (workspace.tabs.back().panes.empty()) {
        workspace.tabs.pop_back();
      }

      throw;
    }
  }

  inline Pane<Memory> &launchBackground(const LaunchTab &request) {
    if (request.launch.cwd_source != 0) {
      throw RequestError{FailureCode::invalid_request, "A background tab requires an explicit working directory"};
    }

    auto &workspace = require(WorkspaceLocation{.id = request.workspace});
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity();
    workspace.tabs.emplace_back(memory_, tab_id, request.label);
    try {
      auto launch = request.launch;
      if (launch.cwd.empty()) {
        launch.cwd = workspace.path;
      }

      auto &pane = panes_.launch(launch, TabLocation{.workspace = {.id = workspace.id}, .tab_id = tab_id}, request.size);
      workspace.tabs.back().panes.push_back(pane.id);
      ++model_.next_tab_id;
      ++model_.workspace_revision;
      return pane;
    } catch (...) {
      workspace.tabs.pop_back();
      throw;
    }
  }

  inline void launchTab(ClientSession<Memory> &client, const LaunchTab &request) {
    const auto &pane = launchBackground(request);
    notifyWorkspaceObservers(model_, pane.location.workspace.id, client.id);
    sendOpened(client, request.request_id, pane, false);
  }

  inline void createPane(ClientSession<Memory> &client, const CreatePane &request) {
    const auto *workspace = model_.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (firstPane(*tab) == nullptr && !model_.tabHeld(request.location))) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    auto &pane = createAt(client, request.location, request.launch, request.size);
    sendOpened(client, request.request_id, pane, true, GenerationField::omitted);
  }

  inline void renameWorkspace(ClientSession<Memory> &client, const RenameWorkspace &request) {
    require(request.workspace).name.assign(request.name);
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.workspace.id, client.id);
    workspaceSnapshot(client, RequestWorkspaceSnapshot{request.request_id, request.workspace});
  }

  inline void renameTab(ClientSession<Memory> &client, const RenameTab &request) {
    auto &tab = requireTab(request.location);
    tab.label.assign(request.label);
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id);
    client.connection.send(TabRenamed{.request_id = request.request_id,
                                      .location = request.location,
                                      .label = tab.label});
  }

  inline void moveTab(ClientSession<Memory> &client, const MoveTab &request) {
    auto &workspace = require(request.location.workspace);
    auto &tab = requireTab(request.location);
    const auto from = static_cast<std::size_t>(&tab - workspace.tabs.data());
    auto to = from;

    if (request.relative_to) {
      auto *relative = workspace.tab(*request.relative_to);
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
      std::rotate(workspace.tabs.begin() + from, workspace.tabs.begin() + from + 1, workspace.tabs.begin() + to + 1);
    } else if (to < from) {
      std::rotate(workspace.tabs.begin() + to, workspace.tabs.begin() + from, workspace.tabs.begin() + from + 1);
    }

    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id);
    client.connection.send(TabMoved{.request_id = request.request_id,
                                    .location = request.location,
                                    .position = static_cast<std::uint16_t>(to)});
  }

  inline void closePane(ClientSession<Memory> &client, const ClosePane &request) {
    if (client.attachment(request.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "pane not attached"};
    }

    auto &pane = panes_.require(request.pane_id);
    pane.requestClose();
  }

  inline void collectExited() {
    for (auto *pane : model_.panes.items()) {
      if (pane == nullptr || !pane->output_closed || !pane->exit_status || pane->observers != 0) {
        continue;
      }

      retainFinalText(*pane);

      const auto location = pane->location;
      const auto identity = pane->id;
      panes_.remove(identity);
      auto *workspace = model_.workspaces.find(location.workspace.id);
      auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
      if (tab == nullptr) {
        leaveEmptyViews(location.workspace.id);
        continue;
      }

      std::erase(tab->panes, identity);
      releaseEmptyTab(location);
      leaveEmptyViews(location.workspace.id);
    }
  }

  inline void holdTab(ClientSession<Memory> &client, const HoldTab &request) {
    TELAR_TRACE("runtime.holdTab");
    const auto *workspace = model_.workspaces.find(request.location.workspace.id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr || workspace->tab(request.location.tab_id) == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    if (request.held && !client.held_tabs.insert(request.location)) {
      throw RequestError{FailureCode::resource_limit, "this client holds too many tabs"};
    }

    if (!request.held && client.held_tabs.erase(request.location)) {
      releaseEmptyTab(request.location);
    }

    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline void releaseHeldTabs(ClientSession<Memory> &client) {
    while (const auto location = client.held_tabs.pop()) {
      releaseEmptyTab(*location);
    }
  }

  inline void closeTab(ClientSession<Memory> &client, const CloseTab &request) {
    auto closed = removeTab(request.location);
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id, closed.previous_workspace);
    closed.request_id = request.request_id;
    client.connection.send(closed);
  }

  inline void closeWorkspace(std::uint64_t identity) {
    auto *workspace = model_.workspaces.find(identity);
    while (workspace != nullptr && !workspace->tabs.empty()) {
      const auto closed = removeTab(TabLocation{WorkspaceLocation{.id = identity}, workspace->tabs.front().id});
      for (auto *client : model_.clients.items()) {
        if (client == nullptr || !client->connection.negotiated || client->connection.closing || client->workspace != identity) {
          continue;
        }

        try {
          publishTabClosed(*client, closed);
        } catch (...) {
          client->connection.closing = true;
        }
      }

      workspace = model_.workspaces.find(identity);
    }
  }

  inline void tabSnapshot(ClientSession<Memory> &client, const RequestTabSnapshot &request) {
    const auto *workspace = model_.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (firstPane(*tab) == nullptr && !model_.tabHeld(request.location))) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    client.connection.defer(request);
  }

  inline void workspaceSnapshot(ClientSession<Memory> &client, const RequestWorkspaceSnapshot &request) {
    const auto *workspace = model_.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "workspace not found"};
    }

    client.connection.defer(request);
    if (client.role == ClientRole::control && client.subscribed) {
      client.workspace = workspace->id;
    }
  }

  inline void publishList(ClientSession<Memory> &client) {
    std::array<WorkspaceListEntry, 64> entries{};
    std::size_t count = 0;

    for (const auto *workspace : model_.workspaces.items()) {
      if (workspace != nullptr) {
        entries[count++] = WorkspaceListEntry{
            .workspace = workspace->id,
            .name = workspace->displayName(),
            .path = workspace->path,
            .tab_count = static_cast<std::uint16_t>(workspace->tabs.size()),
            .branch = workspace->git_branch.view(),
            .dirty = workspace->git_dirty,
        };
      }
    }

    std::array<WorktreeListEntry, Worktrees<Memory>::capacity> worktrees;
    std::size_t worktree_count = 0;
    for (const auto *entry : model_.worktrees.items()) {
      if (entry != nullptr) {
        worktrees[worktree_count++] = entry->entry();
      }
    }

    client.connection.send(WorkspaceList{.revision = model_.workspace_revision,
                                         .entries = std::span<const WorkspaceListEntry>{entries}.first(count),
                                         .worktrees = std::span{worktrees}.first(worktree_count)});
    client.workspace_revision = model_.workspace_revision;
  }

private:
  inline void releaseEmptyTab(TabLocation location) {
    auto *workspace = model_.workspaces.find(location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (tab == nullptr || !tab->panes.empty() || model_.tabHeld(location)) {
      return;
    }

    const auto closed = removeTab(location);
    for (auto *client : model_.clients.items()) {
      if (client == nullptr || !client->connection.negotiated || client->connection.closing || client->workspace != location.workspace.id) {
        continue;
      }

      try {
        publishTabClosed(*client, closed);
      } catch (...) {
        client->connection.closing = true;
      }

      if (closed.workspace_closed) {
        panes_.detachAll(*client);
      }
    }
  }

  inline static void publishTabClosed(ClientSession<Memory> &client, const TabClosed &closed) {
    if (!client.connection.trySend(closed)) {
      client.workspace_resync = ResyncRequired{.workspace = closed.location.workspace,
                                               .workspace_closed = closed.workspace_closed,
                                               .previous_workspace = closed.previous_workspace};
    }
  }

  inline TabClosed removeTab(TabLocation location) {
    auto *workspace = model_.workspaces.find(location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    const auto previous = workspace->tabs.size() == 1 ? previousWorkspace(model_, workspace->id) : std::nullopt;
    for (const auto identity : tab->panes) {
      if (auto *pane = model_.panes.find(identity)) {
        pane->requestClose();
      }
    }

    std::erase_if(workspace->tabs, [&](const auto &candidate) { return candidate.id == location.tab_id; });
    const bool workspace_closed = workspace->tabs.empty();
    if (workspace_closed) {
      model_.workspaces.erase(workspace->id);
    }

    ++model_.workspace_revision;
    return TabClosed{.location = location, .workspace_closed = workspace_closed, .previous_workspace = previous};
  }

  inline void leaveEmptyViews(std::uint64_t workspace) noexcept {
    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && pane->location.workspace.id == workspace && pane->exit_status) {
        return;
      }
    }

    for (auto *client : model_.clients.items()) {
      if (client != nullptr && client->workspace == workspace && client->attachments.empty()) {
        panes_.detachAll(*client);
      }
    }
  }

  inline void retainFinalText(Pane<Memory> &pane) noexcept {
    const auto exit_code = pane.exitCode();
    try {
      TextReader reader{memory_, pane.terminal, ExitedPanes::maximum_bytes};
      reader.read(PaneTextSource::recent, ExitedPanes::kept_rows);
      std::size_t rows = 0;
      checkGhostty(ghostty_terminal_get(pane.terminal.handle(), GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows));
      model_.exited_panes.record(pane.id, pane.generation, PaneText{
                                                               .truncated = reader.truncated() || rows > ExitedPanes::kept_rows,
                                                               .text = reader.text(),
                                                               .exit_code = exit_code,
                                                           });
    } catch (...) {
      model_.exited_panes.record(pane.id, pane.generation, PaneText{.truncated = true, .exit_code = exit_code});
    }
  }

  inline Pane<Memory> &createRoot(ClientSession<Memory> &client, const Launch &launch, TerminalSize size, std::string_view name, bool replace_view = false) {
    if (model_.next_tab_id == 0 || model_.workspaces.nextCounter() == 0) {
      throw RequestError{FailureCode::resource_limit, "could not create workspace"};
    }

    const auto workspace_id = model_.workspaces.nextId();
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, workspace_id, launch.cwd, name);
    const auto tab_id = model_.next_tab_id;
    workspace->tabs.emplace_back(memory_, tab_id, std::string_view{});
    model_.workspaces.insertProvisional(workspace_id, std::move(workspace));
    Pane<Memory> *pane = nullptr;

    try {
      const TabLocation location{.workspace = {.id = workspace_id},
                                 .tab_id = tab_id};
      pane = &panes_.launch(launch, location, size);
      model_.workspaces.find(workspace_id)->tabs.front().panes.push_back(pane->id);
      if (replace_view) {
        panes_.detachAll(client);
      }
      panes_.attach(client, *pane, size);
    } catch (...) {
      if (pane != nullptr) {
        panes_.remove(pane->id);
      }

      model_.workspaces.erase(workspace_id);
      throw;
    }

    model_.workspaces.advanceCounter(workspace_id + 1);
    ++model_.next_tab_id;
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, workspace_id, client.id);
    return *pane;
  }

  inline std::uint64_t nextTabIdentity() const {
    if (model_.next_tab_id == 0) {
      throw RequestError{FailureCode::spawn_failed, "could not start the command"};
    }

    return model_.next_tab_id;
  }

  inline Pane<Memory> &createAt(ClientSession<Memory> &client, TabLocation location, Launch launch, TerminalSize size) {
    auto &workspace = require(location.workspace);
    auto &tab = requireTab(location);
    requireGeometry(client, workspace);

    launch = resolveLaunchDirectory(model_, client, launch, location);
    if (tab.panes.size() == maximum_panes_per_tab) {
      throw RequestError{FailureCode::resource_limit, "Tab pane limit reached"};
    }

    if (launch.cwd.empty()) {
      launch.cwd = workspace.path;
    }

    auto &pane = panes_.launch(launch, location, size);

    try {
      panes_.attach(client, pane, size);
      tab.panes.push_back(pane.id);
    } catch (...) {
      panes_.remove(pane.id);
      throw;
    }

    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, workspace.id, client.id);
    return pane;
  }

  inline Pane<Memory> *firstPane(const Workspace<Memory> &workspace) const noexcept {
    return workspace.tabs.empty() ? nullptr : firstPane(workspace.tabs.front());
  }

  inline Pane<Memory> *firstPane(const Tab<Memory> &tab) const noexcept {
    for (const auto identity : tab.panes) {
      if (auto *pane = model_.panes.find(identity); pane != nullptr && !pane->close_requested && !pane->exit_status) {
        return pane;
      }
    }

    return nullptr;
  }

  inline void requireGeometry(const ClientSession<Memory> &client, Workspace<Memory> &workspace) {
    if (!acquireGeometry(model_, client, workspace)) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }
  }

  inline static void createDirectories(std::string_view path) {
    if (path.empty() || path.size() >= PATH_MAX || path.front() != '/') {
      throw RequestError{FailureCode::invalid_request, "Working directory must be an absolute path"};
    }

    std::array<char, PATH_MAX> directory{};
    std::copy(path.begin(), path.end(), directory.begin());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (directory[index] != '/' && directory[index] != '\0') {
        continue;
      }

      const char separator = directory[index];
      directory[index] = '\0';
      if (::mkdir(directory.data(), 0700) != 0 && errno != EEXIST) {
        throw SystemError{"create working directory"};
      }

      directory[index] = separator;
    }
  }

  enum class GenerationField { included,
                               omitted };

  inline static void sendOpened(ClientSession<Memory> &client, std::uint64_t request, const Pane<Memory> &pane, bool created, GenerationField generation = GenerationField::included) {
    client.connection.send(PaneOpened{
        .request_id = request,
        .pane_id = pane.id,
        .location = pane.location,
        .created = created,
        .pane_generation = generation == GenerationField::included ? pane.generation : 0,
    });
  }

  static constexpr std::size_t maximum_tabs = 64;
  static constexpr std::size_t maximum_panes_per_tab = 64;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
};

}
}

// Interface: runtime/worktree_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorktreeService {
public:
  inline explicit WorktreeService(Memory &memory, RuntimeModel<Memory> &model, WorkspaceService<Memory, Poller, History> &workspaces, LimitService<Memory> &limits)
      : memory_(memory),
        model_(model),
        workspaces_(workspaces),
        limits_(limits) {}

  inline void registerEntry(ClientSession<Memory> &client, const RegisterWorktree &request) {
    workspaces_.require(WorkspaceLocation{.id = request.source});
    if (request.created_by) {
      const auto *pane = model_.panes.find(*request.created_by);
      if (client.verified_pane != *request.created_by || pane == nullptr || client.verified_generation != pane->generation) {
        throw RequestError{FailureCode::foreign_process, "Only a process inside the pane may register for it"};
      }
    }

    const auto result = model_.worktrees.registerEntry(request);
    ++model_.workspace_revision;
    client.connection.send(result);
  }

  inline void launch(ClientSession<Memory> &client, const LaunchWorktree &request) {
    auto &entry = require(request.worktree);
    auto *workspace = entry.workspace ? model_.workspaces.find(*entry.workspace) : nullptr;
    const bool created = workspace == nullptr;
    if (created) {
      const auto identity = model_.workspaces.nextId();
      const auto title = entry.title.view().empty() ? entry.branch.view() : entry.title.view();
      auto owned = makeOwned<Workspace<Memory>>(memory_, memory_, identity, entry.path, utf8Prefix(title, 128));
      workspace = owned.get();
      model_.workspaces.insertProvisional(identity, std::move(owned));
    }

    Pane<Memory> *pane = nullptr;
    try {
      auto launch = request.launch;
      launch.cwd = entry.path;
      launch.cwd_source = 0;
      pane = &workspaces_.launchBackground(LaunchTab{request.request_id, workspace->id, request.label, request.size, launch});
    } catch (...) {
      if (created) {
        model_.workspaces.erase(workspace->id);
      }

      throw;
    }

    model_.workspaces.advanceCounter(workspace->id + 1);
    entry.workspace = workspace->id;
    entry.command_pane = pane->id;
    entry.command_state = CommandState::running;
    entry.command_exit = 0;
    const auto program = launchedProgram(request.launch.arguments);
    entry.command_label.assign(utf8Prefix(program.substr(program.rfind('/') + 1), 48));
    ++model_.workspace_revision;
    client.connection.send(PaneOpened{request.request_id, pane->id, pane->location, created, pane->generation});
  }

  inline void forget(ClientSession<Memory> &client, const ForgetWorktree &request) {
    auto &entry = require(request.worktree);
    if (entry.workspace) {
      workspaces_.closeWorkspace(*entry.workspace);
    }

    model_.worktrees.remove(request.worktree);
    ++model_.workspace_revision;
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  template <typename Background>
  inline void observe(Background &background) {
    if (observing_) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    Worktree<Memory> *selected = nullptr;
    for (auto *entry : model_.worktrees.items()) {
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

  inline void observed(const WorktreeProbeResult &result) {
    if (observing_ != result.identity) {
      return;
    }
    observing_.reset();
    auto *entry = model_.worktrees.find(result.identity);
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
    model_.workspace_revision += changed;
  }

  inline void refresh() noexcept {
    for (auto *entry : model_.worktrees.items()) {
      if (entry == nullptr) {
        continue;
      }

      if (entry->command_pane) {
        const auto *pane = model_.panes.find(*entry->command_pane);
        if (pane != nullptr && pane->exit_status) {
          const auto status = *pane->exit_status;
          entry->command_exit = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
          entry->command_state = CommandState::exited;
          entry->command_pane.reset();
          ++model_.workspace_revision;
        }
      }

      if (entry->workspace && model_.workspaces.find(*entry->workspace) == nullptr) {
        entry->workspace.reset();
        ++model_.workspace_revision;
      }
    }
  }

private:
  inline Worktree<Memory> &require(std::uint64_t identity) const {
    auto *entry = model_.worktrees.find(identity);
    if (entry == nullptr) {
      throw RequestError{FailureCode::worktree_not_found, "worktree not found"};
    }

    return *entry;
  }

  std::optional<std::uint64_t> observing_;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  WorkspaceService<Memory, Poller, History> &workspaces_;
  LimitService<Memory> &limits_;
};

}
}

// Interface: runtime/runtime.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
class Runtime {
public:
  inline explicit Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {})
      : memory_(memory),
        poller_(poller),
        background_(background),
        proxy_(proxy),
        listener_(options.socket),
        model_(memory, options.graphics),
        client_control_(model_),
        runtime_clipboard_(model_),
        limits_(model_),
        admissions_(model_, poller_, limits_),
        client_layouts_(memory, model_),
        panes_(memory, model_, poller, PaneLaunchOptions{listener_.path(), proxy, options.control_policy}, background),
        workspaces_(memory, model_, panes_),
        worktrees_(memory, model_, workspaces_, limits_),
        executions_(memory, model_, poller_, limits_),
        process_inspector_(model_.manifests),
        agents_(memory, model_, panes_, client_layouts_),
        process_probe_(process_inspector_),
        observations_(model_, agents_, limits_, process_probe_, background_),
        media_(model_, panes_, poller_, limits_),
        deferred_reports_(model_, agents_),
        descents_(model_, process_inspector_),
        session_(memory, model_, panes_, client_layouts_, agents_),
        metrics_(host_metrics_),
        workspace_git_probe_(memory),
        workspace_git_(model_, limits_, workspace_git_probe_),
        worktree_detection_(model_, worktree_detector_),
        agent_files_(memory, agents_),
        descriptions_(memory, agents_, background_, options.descriptions),
        telemetry_(options.socket, proxy.status()) {
    model_.cli_executable = options.cli_executable;
    model_.capture_output = options.capture_output;
    model_.manifests = *options.manifests;
    if (options.fresh && !options.session.path.empty()) {
      checkpoint::FileStore<Memory>::setAside(memory, options.session.path);
    }
    session_.configure(options.session);
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
    poller_.watch(worktree_detection_.descriptor(), eventToken(EventSource::worker, 0));
    poller_.watch(agent_files_.descriptor(), eventToken(EventSource::worker, 0));
    if (descriptions_.descriptor() >= 0) {
      poller_.watch(descriptions_.descriptor(), eventToken(EventSource::worker, 0));
    }
  }

  inline void run() {
    IgnoreCaptureEvents captures;
    run(captures);
  }

  template <CaptureEventSource Captures>
  inline void run(Captures &captures) {
    plugins::IgnoreEvents plugins;
    run(captures, plugins);
  }

  template <CaptureEventSource Captures, plugins::EventSource Plugins>
  inline void run(Captures &captures, Plugins &plugins) {
    TELAR_TRACE("runtime.run");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::interactive});
    PluginDelivery delivery{client_control_, limits_};
    const int capture_descriptor = captures.descriptor();
    if (capture_descriptor >= 0) {
      poller_.watch(capture_descriptor, eventToken(EventSource::worker, 0));
    }
    const int plugin_descriptor = plugins.descriptor();
    if (plugin_descriptor >= 0) {
      poller_.watch(plugin_descriptor, eventToken(EventSource::worker, 0));
    }

    while (!model_.stopping) {
      if (captures.collect()) {
        limits_.report(LimitReach{.name = "proxy.capture.joiner_capacity", .noun = "pending exchanges", .value = CaptureJoiner<Memory>::capacity});
      }
      delivery.collect(plugins);
      const auto now = Clock::now();
      auto timeout = publish(now);
      TELAR_DIAGNOSTIC(model_.metrics.system = metrics_.diagnostics());
      TELAR_DIAGNOSTIC(timeout = std::min(timeout, telemetry_.tick(model_, memory_, captures, background_, Clock::now())));

      for (const auto &event : poller_.wait(timeout)) {
        if (event.kind == EventKind::signal) {
          if (event.descriptor == SIGCHLD) {
            continue;
          }

          model_.stopping = true;
          break;
        }

        switch (eventSource(event.token)) {
        case EventSource::listener:
          accept();
          break;
        case EventSource::client:
          clientEvent(event);
          break;
        case EventSource::handshake:
          admissions_.event(event, [this](FileDescriptor descriptor) { admitClient(std::move(descriptor)); });
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
      }
    }

    if (capture_descriptor >= 0) {
      poller_.remove(capture_descriptor);
    }
    if (plugin_descriptor >= 0) {
      poller_.remove(plugin_descriptor);
    }
    stop();
  }

private:
  using Clock = std::chrono::steady_clock;

  inline void accept() {
    constexpr unsigned accept_batch = 16;
    for (unsigned index = 0; index < accept_batch; ++index) {
      auto descriptor = listener_.accept();
      if (!descriptor) {
        return;
      }

      try {
        admissions_.begin(std::move(descriptor));
      } catch (const std::exception &) {
        return;
      }
    }
  }

  inline void admitClient(FileDescriptor descriptor) {
    const auto identity = model_.clients.nextId();
    auto client = makeOwned<ClientSession<Memory>>(memory_, memory_, identity, std::move(descriptor));
    client->connection.negotiated = true;
    client->peer_identity = process_inspector_.peer(client->connection.descriptor());
    auto &retained = *client;
    retained.event_identity = model_.clients.insert(identity, std::move(client));
    try {
      if (retained.event_identity > maximum_event_identity) {
        throw std::bad_alloc{};
      }
      poller_.watch(retained.connection.descriptor(), eventToken(EventSource::client, retained.event_identity));
    } catch (...) {
      dropClient(identity);
      throw;
    }
  }

  inline void dropClient(std::uint64_t identity) noexcept {
    auto *client = model_.clients.find(identity);
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
    panes_.detachAll(*client);
    workspaces_.releaseHeldTabs(*client);
    releaseAllGeometry(model_, identity);
    client_control_.abandon(identity);
    poller_.remove(client->connection.descriptor());
    model_.clients.erase(identity);
  }

  inline void clientEvent(const Event &event) {
    auto *client = model_.clients.findHandle(eventIdentity(event.token));
    if (client == nullptr || client->connection.descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_client_messages));
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        if (client->connection.read_paused) {
          return;
        }

        if (!client->connection.read()) {
          dropClient(client->id);
          return;
        }

        receive(*client);
      } else {
        writeClient(*client, Clock::now());
      }

      updateWriteInterest(*client);
    } catch (const std::exception &) {
      dropClient(client->id);
    }
  }

  inline void paneEvent(const Event &event) {
    TELAR_TRACE("runtime.paneEvent");
    auto *pane = model_.panes.findHandle(eventIdentity(event.token));
    if (pane == nullptr || pane->process->descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        const auto mode = model_.panes.size() == 1 ? Pane<Memory>::ReadMode::burst : Pane<Memory>::ReadMode::once;
        if (!pane->read(mode)) {
          poller_.remove(pane->process->descriptor());
        }
      }

      panes_.flushInput(*pane);
      observations_.observe(*pane);
      media_.updateReadInterest(*pane);
    } catch (const std::exception &) {
      pane->terminal.abortControl();
      pane->requestClose();
      pane->output_closed = true;
      poller_.remove(pane->process->descriptor());
    }
  }

  inline void receive(ClientSession<Memory> &client) {
    client.connection.buffered_requests = client.connection.dispatch([&](std::span<const Byte> payload, DecodeStorage &storage) {
      if (client.connection.closing) {
        return;
      }

      dispatch(client, payload, storage);
    });
  }

  template <typename Message>
  inline void request(ClientSession<Memory> &client, std::span<const Byte> payload, DecodeStorage &storage) {
    const auto message = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{model_.metrics.decode});
      return Codec::decode<Message>(payload, storage);
    }();
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
        const auto decision = deferred_reports_.evaluate(client, *reporter, payload);
        if (decision == ReportDecision::rejected) {
          client.connection.send(RequestFailed{.request_id = request_id, .code = FailureCode::foreign_process, .message = "The report belongs to another agent"});
          return;
        }
        if (decision == ReportDecision::deferred) {
          try {
            observations_.observe(*model_.panes.find(reporter->pane));
          } catch (...) {
            deferred_reports_.cancel(client);
            client.deferred_report.payload.clear();
            throw;
          }
          return;
        }
      }

      handle(client, message);
    } catch (const RequestError &error) {
      if (error.code() == FailureCode::resource_limit) {
        limits_.report(LimitReach{.name = "runtime.request_capacity",
                                  .route = "request"});
      }
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = error.code(),
                                           .message = error.what()});
    } catch (const JsonError &error) {
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::invalid_request,
                                           .message = error.what()});
    } catch (const SystemError &error) {
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::spawn_failed,
                                           .message = error.what()});
    } catch (const std::bad_alloc &) {
      limits_.report(LimitReach{.name = "runtime.memory",
                                .route = "request"});
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::resource_limit,
                                           .message = "Runtime memory or capacity limit reached"});
    }
  }

  inline void dispatch(ClientSession<Memory> &client, std::span<const Byte> payload, DecodeStorage &storage) {
    TELAR_TRACE("runtime.dispatch");
    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_messages));
    const bool recognized = dispatchRequest(static_cast<ClientTag>(payload.front()), [&]<typename Message> {
      request<Message>(client, payload, storage);
    });

    if (!recognized) {
      throw EncodingError{"Unknown request tag"};
    }
  }

  inline void handle(ClientSession<Memory> &client, const ReportLimit &message) {
    limits_.receive(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const QueryLimits &message) {
    limits_.query(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const LaunchTab &message) {
    workspaces_.launchTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RegisterWorktree &message) {
    worktrees_.registerEntry(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const LaunchWorktree &message) {
    worktrees_.launch(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ForgetWorktree &message) {
    worktrees_.forget(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ExecutionRequest &message) {
    executions_.request(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const VerifyPaneDescent &message) {
    descents_.verify(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReportAgent &message) {
    agents_.report(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReportAgentTitle &message) {
    agents_.reportTitle(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReportAgentSession &message) {
    agents_.reportSession(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReportAgentProgress &message) {
    if (!agents_.reportProgress(client, message)) {
      limits_.report(LimitReach{.name = "agents.max_tasks", .noun = "tasks", .value = AgentProgress::task_capacity, .requested = AgentProgress::task_capacity + 1, .route = "agents"});
    }
  }

  inline void handle(ClientSession<Memory> &client, const InterruptAgent &message) {
    agents_.interrupt(client, message);
  }

  inline void handle(ClientSession<Memory> &, const AcknowledgeAgent &message) {
    agents_.acknowledge(message);
  }

  inline void handle(ClientSession<Memory> &client, const QueryAgents &) {
    client.agent_snapshot_requested = true;
  }

  inline void handle(ClientSession<Memory> &client, const ReportAgentCommand &message) {
    const auto &pane = agents_.validateCommand(client, message);
    const auto *workspace = model_.workspaces.find(pane.location.workspace.id);
    background_.submit(client.id, message, RequestContext{.location = pane.location, .history_session = pane.history_session, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .received_at_ms = client.deferred_report.reportTime().milliseconds});
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  inline void handle(ClientSession<Memory> &client, const FindPaths &message) {
    if (!background_.tryPaths(client.id, message, client.connection)) {
      submitBackground(client, message);
    }
  }

  inline void handle(ClientSession<Memory> &client, const OpenEditor &message) {
    const auto *source = model_.panes.find(message.pane_id);
    if (source == nullptr || (message.pane_generation != 0 && source->generation != message.pane_generation)) {
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
      for (const auto *pane : model_.panes.items()) {
        if (pane == nullptr || pane->exit_status || pane->close_requested || pane->location.workspace.id != source->location.workspace.id || pane->location.tab_id != source->location.tab_id || identifyEditor(pane->process_cache.identified.name.view()) != editor) {
          continue;
        }

        const auto group = ::tcgetpgrp(pane->process->descriptor());
        const auto identity = group > 0 ? process_inspector_.identity(group) : std::nullopt;
        if (identity && context.editor_candidate_count < context.editor_candidates.size()) {
          context.editor_candidates[context.editor_candidate_count++] = {pane->id, pane->generation, *identity};
        }
      }
    }

    submitBackground(client, message, context);
    client.editor_source = source->id;
    client.editor_generation = source->generation;
  }

  inline void handle(ClientSession<Memory> &client, const SuggestCommand &message) {
    if (!background_.suggestionsAvailable()) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::unavailable});
      return;
    }

    auto *pane = model_.panes.find(message.pane_id);
    if (pane == nullptr) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
      return;
    }

    try {
      TextReader reader{memory_, pane->terminal, 4096};
      reader.read(PaneTextSource::screen, 24);
      const auto prompt = suggestionPrompt(memory_, pane->cwd, reader.text(), message.text);
      submitBackground(client, message, RequestContext{.prompt = prompt});
    } catch (const RequestError &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    } catch (const std::bad_alloc &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    }
  }

  inline void handle(ClientSession<Memory> &client, const OpenPane &message) {
    workspaces_.open(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CreatePane &message) {
    workspaces_.createPane(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ClosePane &message) {
    workspaces_.closePane(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CreateWorkspace &message) {
    workspaces_.createWorkspace(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RenameWorkspace &message) {
    workspaces_.renameWorkspace(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CreateTab &message) {
    workspaces_.createTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RenameTab &message) {
    workspaces_.renameTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CloseTab &message) {
    workspaces_.closeTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const HoldTab &message) {
    workspaces_.holdTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const MoveTab &message) {
    workspaces_.moveTab(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RequestTabSnapshot &message) {
    workspaces_.tabSnapshot(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RequestWorkspaceSnapshot &message) {
    workspaces_.workspaceSnapshot(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const PaneInput &message) {
    panes_.input(client, message, [this](const Pane<Memory> &pane, std::span<const Byte> bytes) { agents_.observeInput(pane, bytes); });
  }

  inline void handle(ClientSession<Memory> &client, const PaneResize &message) {
    panes_.resize(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReadRuntimeClipboard &message) {
    runtime_clipboard_.read(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CompleteClipboardDesktop &message) {
    if (auto *pane = ClipboardService{model_}.complete(client, message)) {
      panes_.flushInput(*pane);
      media_.updateReadInterest(*pane);
    }
  }

  inline void handle(ClientSession<Memory> &client, const PastePaneClipboard &message) {
    panes_.pasteClipboard(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ConfigurePaneDesktop &message) {
    panes_.configureDesktop(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ConfigureTerminalColors &message) {
    panes_.configureColors(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const SearchPane &message) {
    panes_.search(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CopySelection &message) {
    panes_.copySelection(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReadPane &message) {
    panes_.readText(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const SendPaneText &message) {
    agents_.sendText(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const DetachPane &message) {
    panes_.detach(client, message.pane_id);
  }

  inline void handle(ClientSession<Memory> &client, const FrameAck &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->frames.acknowledge(message.frame_id);
    }
  }

  inline void handle(ClientSession<Memory> &client, const RequestSnapshot &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->frames.requestSnapshot();
    }
  }

  inline void handle(ClientSession<Memory> &client, const SetPaneViewport &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->viewport = message.offset;
      attachment->frames.requestSnapshot();
    }
  }

  inline void handle(ClientSession<Memory> &client, const ConfigureFrameInterval &message) {
    client.frame_interval = std::chrono::nanoseconds{message.interval_ns};
  }

  inline void handle(ClientSession<Memory> &client, const RequestRuntimeState &message) {
    if (client.identity != 0 && client.identity != message.client_identity) {
      throw EncodingError{"Subscribed client identity cannot change"};
    }
    if (client.subscribed) {
      return;
    }

    client.identity = message.client_identity;
    client.interactive = message.interactive;
    client.subscribed = true;
    client.workspace_revision = 0;
    client.agent_snapshot_requested = true;
  }

  inline void handle(ClientSession<Memory> &client, const QueryClients &message) {
    client_control_.list(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const DetachClient &message) {
    client_control_.detach(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RequestClientCommand &message) {
    client_control_.requestCommand(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CompleteClientCommand &message) {
    client_control_.completeCommand(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const RequestPaneFocus &message) {
    client_control_.requestFocus(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const CompletePaneFocus &message) {
    client_control_.completeFocus(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ShowNotification &message) {
    client_control_.notify(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const UpdateClientLayout &message) {
    client_layouts_.retain(client.identity, message);
  }

  inline void handle(ClientSession<Memory> &client, const QueryHistory &message) {
    submitBackground(client, message, RequestContext{.persistent_client = client.role == ClientRole::interactive});
  }

  inline void handle(ClientSession<Memory> &client, const ImportHistory &message) {
    submitBackground(client, message);
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  inline void handle(ClientSession<Memory> &client, const DeleteHistory &message) {
    submitBackground(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const PruneHistory &message) {
    submitBackground(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const ReadHistoryOutput &message) {
    submitBackground(client, message);
  }

  inline void handle(ClientSession<Memory> &client, const HistoryStatsQuery &message) {
    submitBackground(client, message);
  }

  template <typename Message>
  inline void submitBackground(ClientSession<Memory> &client, const Message &message, RequestContext context = {}) {
    if constexpr (std::same_as<Message, OpenEditor>) {
      if (client.editor_source != 0) {
        throw RequestError{FailureCode::resource_limit, "An editor request is already pending"};
      }
    }

    background_.submit(client.id, message, context);
  }

  inline void collectBackground() {
    TELAR_TRACE("runtime.collectBackground");
    session_.collect();
    observations_.collect();
    media_.collect();
    descents_.collect();
    answerDeferredReports();
    metrics_.collect();
    runtime_clipboard_.collect();
    workspace_git_.collect(Clock::now());
    worktree_detection_.collect();
    agent_files_.collect();
    descriptions_.collect();
    if (const auto failures = background_.takeHistoryFailures()) {
      limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed events", .requested = failures, .route = "history"});
    }
    background_.collectWorktrees([&](const WorktreeProbeResult &result) { worktrees_.observed(result); });
    background_.collect([&](std::uint64_t client_id, ClientTag request_tag, std::span<const Byte> payload) {
      if (request_tag == ClientTag::import_history) {
        return;
      }

      if (request_tag == ClientTag::report_agent_command) {
        if (payload.front() == static_cast<Byte>(ServerTag::request_failed)) {
          limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed commands", .route = "history"});
        }
        return;
      }

      auto *client = model_.clients.find(client_id);
      if (client == nullptr || client->connection.closing) {
        return;
      }

      try {
        if (payload.front() == static_cast<Byte>(ServerTag::editor_opened)) {
          std::array<Byte, 256> scratch;
          DecodeStorage storage{scratch};
          auto reply = Codec::decode<EditorOpened>(payload, storage);
          const auto *source = model_.panes.find(client->editor_source);
          const auto *target = model_.panes.find(reply.pane_id);
          if (source == nullptr || source->generation != client->editor_generation || source->exit_status || source->close_requested ||
              (reply.outcome == EditorOutcome::opened && (target == nullptr || target->generation != reply.pane_generation || target->exit_status || target->close_requested || target->location.workspace.id != source->location.workspace.id || target->location.tab_id != source->location.tab_id))) {
            reply.outcome = EditorOutcome::failed;
          }
          client->editor_source = 0;
          client->connection.send(reply);
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
        updateWriteInterest(*client);
      } catch (...) {
        dropClient(client_id);
      }
    });
  }

  inline void handle(ClientSession<Memory> &client, const ConfigureGraphics &message) {
    client.shared_graphics = message.shared;
    for (auto &attachment : client.attachments) {
      attachment->graphics.configure(message.shared);
    }
  }

  inline static bool isHistoryRequest(ClientTag tag) noexcept {
    switch (tag) {
    case ClientTag::query_history:
    case ClientTag::import_history:
    case ClientTag::delete_history:
    case ClientTag::prune_history:
    case ClientTag::read_history_output:
    case ClientTag::history_stats:
      return true;
    default:
      return false;
    }
  }

  inline void handle(ClientSession<Memory> &client, const GraphicsCredit &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->graphics.returnCredit(message.bytes);
    }
  }

  inline void handle(ClientSession<Memory> &client, const RequestGraphicsSnapshot &message) {
    if (auto *attachment = client.attachment(message.pane_id)) {
      attachment->graphics.requestSnapshot();
    }
  }

  inline void handle(ClientSession<Memory> &, const RuntimeStop &) {
    model_.stopping = true;
  }

  inline std::chrono::nanoseconds publish(Clock::time_point now) {
    TELAR_TRACE("runtime.publish");
    admissions_.expire(now);
    runtime_clipboard_.expire(now);
    media_.collect();
    std::chrono::nanoseconds timeout = std::chrono::milliseconds{100};
    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        try {
          if (ClipboardService{model_}.advance(*pane, now) && !pane->output_closed) {
            panes_.flushInput(*pane);
            media_.updateReadInterest(*pane);
          }
        } catch (const std::exception &) {
          pane->terminal.abortControl();
          pane->requestClose();
          pane->output_closed = true;
          poller_.remove(pane->process->descriptor());
        }
      }
      if (pane != nullptr && !pane->exit_status) {
        pane->exit_status = pane->process->reap();
      }

      if (pane != nullptr && pane->exit_status && pane->output_closed && !pane->exit_observed) {
        pane->observer->shellExit(*pane->exitCode());
        pane->exit_observed = true;
      }
    }

    if (executions_.refresh()) {
      timeout = std::min(timeout, std::chrono::nanoseconds{std::chrono::milliseconds{10}});
    }

    try {
      observations_.refresh();
      answerDeferredReports();
      agents_.refresh();
      agent_files_.tick(now);
      descriptions_.tick();
      worktree_detection_.tick();
    } catch (const std::bad_alloc &) {
    } catch (const RequestError &) {
    }

    worktrees_.refresh();
    worktrees_.observe(background_);
    workspaces_.collectExited();
    timeout = std::min(timeout, session_.tick(now));
    timeout = std::min(timeout, metrics_.tick(now));
    timeout = std::min(timeout, workspace_git_.tick(now));

    for (auto *client : model_.clients.items()) {
      if (client == nullptr) {
        continue;
      }

      if (client->connection.closing && !client->connection.hasOutput()) {
        dropClient(client->id);
        continue;
      }

      try {
        if (client->connection.closing) {
          client->connection.write(ResponseProjection{memory_, model_});
          updateWriteInterest(*client);
          continue;
        }

        if (client->connection.buffered_requests && !client->connection.read_paused) {
          receive(*client);
          timeout = std::chrono::nanoseconds::zero();
        }

        if (panes_.advanceSearch(*client)) {
          timeout = std::chrono::nanoseconds::zero();
        }

        timeout = std::min(timeout, writeClient(*client, now));
        updateWriteInterest(*client);
      } catch (const std::exception &) {
        dropClient(client->id);
      }
    }

    media_.start();
    return timeout;
  }

  inline std::chrono::nanoseconds writeClient(ClientSession<Memory> &client, Clock::time_point now) {
    StateProjection state{workspaces_, agents_, metrics_, client_layouts_, proxy_};
    ClientDelivery delivery{memory_, model_};
    const auto result = delivery.write(client, state, now);
    if (result.detach_pane) {
      panes_.release(client, *result.detach_pane);
    }
    return result.timeout;
  }

  inline void updateWriteInterest(ClientSession<Memory> &client) {
    const bool enabled = client.connection.hasOutput();
    if (enabled != client.connection.write_interest) {
      poller_.writeInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), enabled);
      client.connection.write_interest = enabled;
    }

    const bool readable = !client.connection.read_paused;
    if (readable != client.connection.read_interest) {
      poller_.readInterest(client.connection.descriptor(), eventToken(EventSource::client, client.event_identity), readable);
      client.connection.read_interest = readable;
    }
  }

  inline void answerDeferredReports() {
    deferred_reports_.answerDue(ObservationTime::now(), [this](ClientSession<Memory> &client, std::span<const Byte> payload) {
      client.connection.replay(payload, [&](std::span<const Byte> bytes, DecodeStorage &storage) { dispatch(client, bytes, storage); });
      updateWriteInterest(client);
    });
  }

  inline void stop() noexcept {
    admissions_.clear();
    session_.finish();
    for (auto *client : model_.clients.items()) {
      if (client == nullptr) {
        continue;
      }

      try {
        client->connection.send(RuntimeStopping{});
        client->connection.write(ResponseProjection{memory_, model_});
      } catch (...) {
      }

      dropClient(client->id);
    }

    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        pane->process->signal(SIGTERM);
        pane->observer->finishSession();
      }
    }

    observations_.finish();
    media_.finish();
  }

  Memory &memory_;
  Poller &poller_;
  Background &background_;
  ProxyClientConfiguration proxy_;
  LocalListener listener_;
  RuntimeModel<Memory> model_;
  ClientControl<Memory> client_control_;
  RuntimeClipboardService<Memory> runtime_clipboard_;
  LimitService<Memory> limits_;
  ClientAdmission<Memory, Poller> admissions_;
  ClientLayouts<Memory> client_layouts_;
  PaneService<Memory, Poller, Background> panes_;
  WorkspaceService<Memory, Poller, Background> workspaces_;
  WorktreeService<Memory, Poller, Background> worktrees_;
  ExecutionService<Memory, Poller> executions_;
  ProcessInspector process_inspector_;
  AgentService<Memory, Poller, Background> agents_;
  ProcessProbe<ProcessInspector> process_probe_;
  PaneObservationService<Memory, decltype(agents_), decltype(limits_), decltype(process_probe_), Background> observations_;
  MediaService<Memory, Poller, decltype(limits_), Background> media_;
  DeferredReports<Memory, decltype(agents_)> deferred_reports_;
  DescentService<Memory, ProcessInspector> descents_;
  checkpoint::SessionStore<Memory, Poller, decltype(agents_), Background> session_;
  NativeHostMetrics host_metrics_;
  HostMetricsService<NativeHostMetrics> metrics_;
  WorkspaceGitProbe<Memory> workspace_git_probe_;
  WorkspaceGitService<Memory, decltype(workspace_git_probe_)> workspace_git_;
  WorktreeDetectionProbe worktree_detector_;
  WorktreeDetectionService<Memory, WorktreeDetectionProbe> worktree_detection_;
  AgentFileService<Memory, decltype(agents_)> agent_files_;
  DescriptionService<Memory, decltype(agents_), Background> descriptions_;
  [[no_unique_address]] diagnostics::RuntimeTelemetry telemetry_;
};

template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {}) -> Runtime<Memory, Poller, Background>;

}
}
