module;
#include "tbc/view.hpp"
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
  using Panes = PaneService<Memory, Poller, History>;

  inline explicit AgentService(Memory &memory)
      : agents_(memory) {}

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
    return descriptions_.nextDescription(agents_);
  }

  inline std::optional<HistorySessionTitle> completeDescription(const DescriptionResult &result) {
    return descriptions_.completeDescription(agents_, result);
  }

  inline void report(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const ReportAgent &request) {
    auto &pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto *existing = agents_.find(pane.id, pane.generation);
    if (existing == nullptr && request.state == AgentReportState::continuing) {
      client.connection.send(RequestCompleted{.request_id = request.request_id});
      return;
    }

    if (existing == nullptr) {
      existing = &ensure(pane);
    }
    auto &agent = *existing;
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

  inline void reportSession(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const ReportAgentSession &request) {
    auto &pane = require(model.panes, request.pane_id, request.pane_generation);
    ensure(pane).setSession(request.session);
    agents_.changed();
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  inline void reportTitle(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const ReportAgentTitle &request) {
    auto &pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
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

  inline bool reportProgress(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const ReportAgentProgress &request) {
    auto &pane = authorize(model.panes, client, request.pane_id, request.pane_generation, request.provider);
    auto &agent = ensure(pane);
    agent.evidence.claim(request.provider);
    const bool applied = agent.progress.apply(request);

    if (!request.cwd.empty()) {
      const auto *worktree = model.worktrees.containing(request.cwd);
      if (worktree != nullptr) {
        agent.worktree = worktree->id;
      } else if (!request.work_tree_path.empty()) {
        const auto branch = request.work_tree_branch.empty() ? request.work_tree_path.substr(request.work_tree_path.rfind('/') + 1) : request.work_tree_branch;
        const auto result = model.worktrees.registerEntry(RegisterWorktree{.source = model.worktrees.sourceFor(pane.location.workspace.id),
                                                                            .created_by = pane.id,
                                                                            .origin = WorktreeOrigin::external,
                                                                            .path = request.work_tree_path,
                                                                            .branch = branch});
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

  inline tbc::view<Pane<Memory> &, tbc::lt::a> validateCommand(tbc::view<RuntimeModel<Memory> &, tbc::lt::a> model, ClientSession<Memory> &client, const ReportAgentCommand &request) {
    return authorize(model.panes, client, request.pane_id, request.pane_generation, model.manifests.named(request.provider));
  }

  // Sends text to a pane, which its caller says no attached window focuses.
  inline void sendText(RuntimeModel<Memory> &model, Panes &panes, ClientSession<Memory> &client, const SendPaneText &request, bool focused) {
    auto &pane = Panes::requireGeneration(model.panes, request.pane_id, request.pane_generation);
    if (pane.exit_status || pane.output_closed) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }
    if (focused) {
      throw RequestError{FailureCode::pane_focused, "The pane has focus in an attached window"};
    }
    if (request.mode == PaneTextMode::prompt && blocked(pane)) {
      throw RequestError{FailureCode::agent_blocked, "Agent is waiting for a decision"};
    }
    std::array<char, 192> prefix{};
    std::size_t length = 0;
    const auto *sender = request.sender ? model.panes.find(*request.sender) : nullptr;
    if (request.mode == PaneTextMode::prompt && sender != nullptr) {
      if (!prompt_budget_.spend(sender->id, pane.id, std::chrono::steady_clock::now())) {
        throw RequestError{FailureCode::prompt_rate_limited, "Prompt budget for this pane is spent; wait for its answer"};
      }
      std::string_view name = "a telar pane";
      if (const auto *workspace = model.workspaces.find(sender->location.workspace.id)) {
        name = workspace->displayName();
      }
      for (const auto *worktree : model.worktrees.items()) {
        if (worktree != nullptr && worktree->workspace == sender->location.workspace.id) {
          name = worktree->branch.view();
          break;
        }
      }
      name = utf8Prefix(name, 64);
      length = static_cast<std::size_t>(std::snprintf(prefix.data(), prefix.size(), "[telar: from %.*s, pane %llu] ", static_cast<int>(name.size()), name.data(), static_cast<unsigned long long>(sender->id)));
    }
    panes.sendText(model.panes, client, request, {prefix.data(), length}, [this](const Pane<Memory> &target, std::span<const Byte> bytes) { observeInput(target, bytes); });
  }

  inline void acknowledge(const AcknowledgeAgent &request) noexcept {
    if (auto *agent = agents_.find(request.pane_id, request.pane_generation); agent != nullptr && agent->status == AgentStatus::done) {
      agent->acknowledged = true;
      if (agent->project(wallMilliseconds())) {
        projected(agent->pane, agent->generation);
      }
    }
  }

  // Interrupts a pane's agent, which its caller says no attached window focuses.
  inline void interrupt(RuntimeModel<Memory> &model, Panes &panes, ClientSession<Memory> &client, const InterruptAgent &request, bool focused) {
    auto &pane = Panes::requireGeneration(model.panes, request.pane_id, request.pane_generation);
    if (pane.exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }
    if (focused) {
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
    const auto *manifest = model.manifests.find(agent->provider);
    if (manifest == nullptr || manifest->interrupt == AgentInterruptKey::none) {
      throw RequestError{FailureCode::interrupt_unsupported, "Agent declares no interrupt key"};
    }

    std::array<Byte, 128> encoded;
    const bool control_c = manifest->interrupt == AgentInterruptKey::control_c;
    const auto bytes = pane.terminal.encodeKey(control_c ? GHOSTTY_KEY_C : GHOSTTY_KEY_ESCAPE, control_c ? GHOSTTY_MODS_CTRL : 0, encoded);
    const auto repeats = manifest->interrupt == AgentInterruptKey::escape_twice ? 2 : 1;
    if (panes.admitInput(pane, bytes.size() * repeats)) {
      for (int index = 0; index < repeats; ++index) {
        pane.enqueueInput(bytes);
      }
      panes.flushInput(pane);
    }
    agent->report(ReportAgent{.state = AgentReportState::settling,
                              .event = "Interrupted by telar"});
    agent->interrupt_at = now;
    agent->interrupt_revision = pane.terminal.contentRevision();
    projected(agent->pane, agent->generation);
    client.connection.send(RequestCompleted{.request_id = request.request_id});
  }

  // Whether an attached window focuses a pane.
  inline static bool focused(const ClientStore<Memory> &clients, const ClientLayouts<Memory> &layouts, std::uint64_t pane) noexcept {
    for (const auto *client : clients.items()) {
      if (client != nullptr && client->role == ClientRole::interactive && !client->connection.closing && layouts.focusedPane(client->identity) == pane) {
        return true;
      }
    }

    return false;
  }

  inline bool blocked(const Pane<Memory> &pane) const noexcept {
    const auto *agent = agents_.find(pane.id, pane.generation);
    return agent != nullptr && agent->status == AgentStatus::blocked;
  }

  inline void query(const RuntimeModel<Memory> &model, ClientSession<Memory> &client) {
    snapshots_.publish(client, model, agents_);
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
    if (!identity || provider == AgentProvider::unknown) {
      return;
    }

    if (agent == nullptr) {
      if (agents_.records().size() == AgentRegistry<Memory>::capacity) {
        return;
      }

      agent = &ensure(pane);
    }

    const bool changed = agent->observeProcess(*identity, provider);
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
    if (changed) {
      projected(pane.id, pane.generation);
    }
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
        projected(agent->pane, agent->generation);
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
      if (alerts(*agent, previous)) {
        sounds_.push(*agent);
      }
      projected(agent->pane, agent->generation);
    }
  }

  inline void refresh(RuntimeModel<Memory> &model, Panes &panes, const ClientStore<Memory> &clients, const ClientLayouts<Memory> &layouts, std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now()) {
    agents_.removeIf([&](const Agent &agent) { const auto *pane = model.panes.find(agent.pane); return pane == nullptr || pane->generation != agent.generation || (!agent.evidence.choose(wallMilliseconds()) && agent.observed_at != 0); });
    for (auto *pane : model.panes.items()) {
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

  inline Agent &ensure(Pane<Memory> &pane) {
    auto &agent = agents_.ensure(pane.id, pane.generation);
    agent.session_id = pane.history_session;
    return agent;
  }

  // Sends the agent sounds reported since the last delivery to subscribed clients.
  inline void deliverSounds(ClientStore<Memory> &clients) noexcept {
    for (const auto &notification : sounds_.queued()) {
      for (auto *client : clients.items()) {
        if (client == nullptr || !client->subscribed || client->connection.closing) {
          continue;
        }
        try {
          client->connection.trySend(notification);
        } catch (...) {
          client->connection.closing = true;
        }
      }
    }
    sounds_.clear();
  }

private:
  // Stamps an agent whose projection changed, named by its pane: it may queue for a description and
  // takes the next sequence. The table lends one entry at a time, so the caller holds none across it.
  inline void projected(std::uint64_t pane, std::uint64_t generation) noexcept {
    const auto pending = DescriptionQueue<Memory>::pending(agents_);
    if (auto *agent = agents_.find(pane, generation)) {
      descriptions_.project(pending, *agent);
      agent->sequence = ++sequence_;
    }
    agents_.changed();
  }

  // Whether a change of status calls for a sound.
  inline static bool alerts(const Agent &agent, AgentStatus previous) noexcept {
    return (agent.status == AgentStatus::done && previous == AgentStatus::working) || (agent.status == AgentStatus::blocked && previous != AgentStatus::blocked);
  }

  // Ends an interrupt once its pane settles; whether the agent's projection changed.
  inline static bool settleInterrupt(Panes &panes, bool focused, Pane<Memory> &pane, Agent &agent, std::chrono::steady_clock::time_point now) {
    bool settled = false;
    if (hasIdleScreen(agent.provider)) {
      if (pane.terminal.contentRevision() <= agent.interrupt_revision || !pane.terminal.outputSettled()) {
        return false;
      }
      pane.terminal.refresh();
      const auto observation = AgentScreenReader{pane.terminal}.observe(agent.provider);
      if (observation.restored_draft && !agent.interrupt_draft_cleared && !focused) {
        std::array<Byte, 128> encoded;
        const auto bytes = pane.terminal.encodeKey(GHOSTTY_KEY_C, GHOSTTY_MODS_CTRL, encoded);
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

  inline static Pane<Memory> &require(PaneStore<Memory> &panes, std::uint64_t identity, std::uint64_t generation) {
    auto &pane = Panes::requireGeneration(panes, identity, generation);
    if (generation == 0 || pane.exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    return pane;
  }

  inline tbc::view<Pane<Memory> &, tbc::lt::a> authorize(tbc::view<PaneStore<Memory> &, tbc::lt::a> panes, const ClientSession<Memory> &client, std::uint64_t pane_id, std::uint64_t generation, AgentProvider provider) {
    TELAR_TRACE("agents.authorize");
    auto &pane = require(panes, pane_id, generation);
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

  // Queues an agent's sound, delivered once no client is borrowed.
  // Agent sounds queued while a client is borrowed, delivered to the subscribed clients afterwards.
  class SoundQueue {
  public:
    inline void push(const Agent &agent) noexcept {
      if (count_ < entries_.size()) {
        entries_[count_++] = AgentSoundNotification{.pane_id = agent.pane,
                                                     .pane_generation = agent.generation,
                                                     .sound = agent.status == AgentStatus::blocked ? AgentSound::needs_input : AgentSound::ready};
      }
    }

    inline std::span<const AgentSoundNotification> queued() const noexcept {
      return std::span{entries_}.first(count_);
    }

    inline void clear() noexcept {
      count_ = 0;
    }

  private:
    std::array<AgentSoundNotification, 32> entries_{};
    std::size_t count_ = 0;
  };

  AgentRegistry<Memory> agents_;
  DescriptionQueue<Memory> descriptions_;
  AgentSnapshotBuilder<Memory> snapshots_;
  PromptBudget prompt_budget_;
  std::uint64_t sequence_ = 0;
  std::uint64_t session_watch_revision_ = 0;
  bool has_session_files_ = false;
  SoundQueue sounds_;
};

}
}

// Interface: runtime/launch_directory.cppm
export {
namespace telar::runtime {

using LaunchDirectoryScope = std::variant<std::monostate, WorkspaceLocation, TabLocation>;

// Storage for a launch's working directory taken from the model, so that the launch borrows none of
// the model a launch then changes.
using LaunchDirectory = FixedText<4096>;

// Points a launch at a copy of a directory.
inline void ownDirectory(tbc::view<Launch &, tbc::lt::a> launch, tbc::view<LaunchDirectory &, tbc::lt::a> storage, std::string_view directory) {
  if (directory.size() > 4096) {
    throw RequestError{FailureCode::invalid_request, "working directory is too long"};
  }
  storage.assign(directory);
  launch.cwd = storage.view();
}

// The launch with the directory of the pane it names as its source, copied into `directory`.
template <Allocator Memory>
tbc::view<Launch, tbc::lt::a> resolveLaunchDirectory(const RuntimeModel<Memory> &model, const ClientSession<Memory> &client, tbc::view<Launch, tbc::lt::a> launch, tbc::view<LaunchDirectory &, tbc::lt::a> directory, LaunchDirectoryScope scope = {}) {
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

  ownDirectory(launch, directory, pane->cwd);
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

// Shows plugins' notifications on the clients and reports their dropped work as limits.
template <Allocator Memory>
class PluginDelivery {
public:
  inline explicit PluginDelivery(LimitService<Memory> &limits) noexcept
      : limits_(limits) {}

  template <plugins::EventSource Source>
  inline void collect(ClientStore<Memory> &clients, Source &source) {
    source.collect([&](const plugins::EffectBatch &batch) {
      for (const auto &notification : std::span{batch.notifications}.first(batch.count)) {
        publish(clients, notification);
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
  inline static void publish(ClientStore<Memory> &clients, const NotificationBody &body) {
    const Notification notification{body};
    std::array<Byte, validation_bytes> validation;
    std::span<Byte> remaining{validation};
    try {
      Codec::encode(notification, remaining);
    } catch (const EncodingError &) {
      return;
    }
    ClientControl<Memory>::publish(clients, notification);
  }

  inline void reportGrowth(std::uint64_t current, std::uint64_t previous, const LimitReach &reach) {
    if (current > previous) {
      limits_.report(reach);
    }
  }

  static constexpr std::size_t validation_bytes = 512;
  LimitService<Memory> &limits_;
  plugins::TapMetrics previous_;
};

template <Allocator Memory>
PluginDelivery(LimitService<Memory> &limits) -> PluginDelivery<Memory>;

}
}

// Interface: runtime/workspace_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorkspaceService {
public:
  using Panes = PaneService<Memory, Poller, History>;

  inline explicit WorkspaceService(Memory &memory)
      : memory_(memory) {}

  inline static Workspace<Memory> &require(WorkspaceStore<Memory> &workspaces, WorkspaceLocation location) {
    auto *workspace = workspaces.find(location.id);
    if (location.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
    }

    return *workspace;
  }

  inline static Tab<Memory> &requireTab(WorkspaceStore<Memory> &workspaces, TabLocation location) {
    auto *tab = require(workspaces, location.workspace).tab(location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    return *tab;
  }

  // The colors of a workspace's geometry owner, which its new panes take.
  inline static tbc::view<const ConfigureTerminalColors *, tbc::lt::a> ownerColors(const WorkspaceStore<Memory> &workspaces, tbc::view<const ClientStore<Memory> &, tbc::lt::a> clients, std::uint64_t workspace) noexcept {
    const auto *found = workspaces.find(workspace);
    const auto *owner = found != nullptr && found->geometry_client ? clients.find(*found->geometry_client) : nullptr;
    return owner == nullptr ? nullptr : &owner->colors;
  }

  inline void open(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const OpenPane &request) {
    std::optional<std::uint64_t> pane;
    bool created = false;

    if (request.target.kind == PaneTarget::Kind::pane) {
      const auto &target = Panes::require(model.panes, request.target.id);
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
      const Workspace<Memory> *workspace = nullptr;
      for (const auto *candidate : model.workspaces.items()) {
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

    auto &client = requireClient(clients, client_id);
    panes.attach(model, client, *pane, request.size);
    sendOpened(client, request.request_id, Panes::require(model.panes, *pane), created);
  }

  inline void createWorkspace(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const CreateWorkspace &request) {
    LaunchDirectory directory;
    auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), request.launch, directory);
    if (request.create_cwd && request.launch.cwd_source == 0) {
      createDirectories(launch.cwd);
    }

    const auto pane = createRoot(model, panes, clients, client_id, launch, request.size, request.name, true);
    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  inline void createTab(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const CreateTab &request) {
    if (!acquireGeometry(model.panes, model.metrics, requireClient(clients, client_id), require(model.workspaces, request.workspace))) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }
    LaunchDirectory directory;
    const auto launch = resolveLaunchDirectory(model, requireClient(clients, client_id), request.launch, directory, request.workspace);
    auto &workspace = require(model.workspaces, request.workspace);
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity(model);
    workspace.tabs.emplace_back(memory_, tab_id, request.label);

    try {
      const auto pane = createAt(model, panes, clients, client_id, TabLocation{request.workspace, tab_id}, launch, request.size);
      ++model.next_tab_id;
      const auto &opened = Panes::require(model.panes, pane);
      const auto &tabs = require(model.workspaces, request.workspace).tabs;
      requireClient(clients, client_id).connection.send(TabCreated{
          .request_id = request.request_id,
          .location = opened.location,
          .position = static_cast<std::uint16_t>(tabs.size() - 1),
          .label = tabs.back().label,
          .root_pane_id = opened.id,
          .pane_generation = opened.generation,
      });
    } catch (...) {
      if (auto *current = model.workspaces.find(request.workspace.id); current != nullptr && current->tabs.back().panes.empty()) {
        current->tabs.pop_back();
      }

      throw;
    }
  }

  // A tab launched without a client, in the colors of its workspace's geometry owner.
  inline std::uint64_t launchBackground(RuntimeModel<Memory> &model, Panes &panes, const ConfigureTerminalColors *owner_colors, const LaunchTab &request) {
    if (request.launch.cwd_source != 0) {
      throw RequestError{FailureCode::invalid_request, "A background tab requires an explicit working directory"};
    }

    auto &workspace = require(model.workspaces, WorkspaceLocation{.id = request.workspace});
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity(model);
    workspace.tabs.emplace_back(memory_, tab_id, request.label);
    try {
      auto launch = request.launch;
      LaunchDirectory directory;
      if (launch.cwd.empty()) {
        ownDirectory(launch, directory, workspace.path);
      }

      const auto pane = panes.launch(model, owner_colors, launch, TabLocation{.workspace = {.id = request.workspace}, .tab_id = tab_id}, request.size).id;
      require(model.workspaces, WorkspaceLocation{.id = request.workspace}).tabs.back().panes.push_back(pane);
      ++model.next_tab_id;
      ++model.workspace_revision;
      return pane;
    } catch (...) {
      if (auto *current = model.workspaces.find(request.workspace)) {
        current->tabs.pop_back();
      }
      throw;
    }
  }

  inline void launchTab(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const LaunchTab &request) {
    const auto pane = launchBackground(model, panes, ownerColors(model.workspaces, clients, request.workspace), request);
    const auto &launched = Panes::require(model.panes, pane);
    notify(launched.location.workspace.id, client_id);
    sendOpened(requireClient(clients, client_id), request.request_id, launched, false);
  }

  inline void createPane(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const CreatePane &request) {
    const auto *workspace = model.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, request.location))) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    const auto pane = createAt(model, panes, clients, client_id, request.location, request.launch, request.size);
    sendOpened(requireClient(clients, client_id), request.request_id, Panes::require(model.panes, pane), true, GenerationField::omitted);
  }

  inline void renameWorkspace(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const RenameWorkspace &request) {
    require(model.workspaces, request.workspace).name.assign(request.name);
    ++model.workspace_revision;
    notify(request.workspace.id, client.id);
    workspaceSnapshot(model, client, RequestWorkspaceSnapshot{request.request_id, request.workspace});
  }

  inline void renameTab(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const RenameTab &request) {
    auto &tab = requireTab(model.workspaces, request.location);
    tab.label.assign(request.label);
    ++model.workspace_revision;
    notify(request.location.workspace.id, client.id);
    client.connection.send(TabRenamed{.request_id = request.request_id,
                                      .location = request.location,
                                      .label = tab.label});
  }

  inline void moveTab(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const MoveTab &request) {
    auto &workspace = require(model.workspaces, request.location.workspace);
    auto *tab = workspace.tab(request.location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }
    const auto from = static_cast<std::size_t>(tab - workspace.tabs.data());
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

    ++model.workspace_revision;
    notify(request.location.workspace.id, client.id);
    client.connection.send(TabMoved{.request_id = request.request_id,
                                    .location = request.location,
                                    .position = static_cast<std::uint16_t>(to)});
  }

  inline static void closePane(RuntimeModel<Memory> &model, const ClientSession<Memory> &client, const ClosePane &request) {
    if (client.attachment(request.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "pane not attached"};
    }

    Panes::require(model.panes, request.pane_id).requestClose();
  }

  inline void collectExited(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients) {
    for (std::size_t slot = 0; slot < model.panes.items().size(); ++slot) {
      auto *pane = model.panes.items()[slot];
      if (pane == nullptr || !pane->output_closed || !pane->exit_status || pane->observers != 0) {
        continue;
      }

      retainFinalText(model.exited_panes, *pane);

      const auto location = pane->location;
      const auto identity = pane->id;
      panes.remove(model, clients, identity);
      auto *workspace = model.workspaces.find(location.workspace.id);
      auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
      if (tab == nullptr) {
        leaveEmptyViews(model, panes, clients, location.workspace.id);
        continue;
      }

      std::erase(tab->panes, identity);
      releaseEmptyTab(model, panes, clients, location);
      leaveEmptyViews(model, panes, clients, location.workspace.id);
    }
  }

  inline void holdTab(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const HoldTab &request) {
    TELAR_TRACE("runtime.holdTab");
    const auto *workspace = model.workspaces.find(request.location.workspace.id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr || workspace->tab(request.location.tab_id) == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    auto &client = requireClient(clients, client_id);
    if (request.held && !client.held_tabs.insert(request.location)) {
      throw RequestError{FailureCode::resource_limit, "this client holds too many tabs"};
    }

    if (!request.held && client.held_tabs.erase(request.location)) {
      releaseEmptyTab(model, panes, clients, request.location);
    }

    if (auto *current = clients.find(client_id)) {
      current->connection.send(RequestCompleted{.request_id = request.request_id});
    }
  }

  inline void releaseHeldTabs(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id) {
    while (auto *client = clients.find(client_id)) {
      const auto location = client->held_tabs.pop();
      if (!location) {
        return;
      }
      releaseEmptyTab(model, panes, clients, *location);
    }
  }

  inline void closeTab(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const CloseTab &request) {
    auto closed = removeTab(model, request.location);
    notify(request.location.workspace.id, client.id, closed.previous_workspace);
    closed.request_id = request.request_id;
    client.connection.send(closed);
  }

  inline void closeWorkspace(RuntimeModel<Memory> &model, ClientStore<Memory> &clients, std::uint64_t identity) {
    auto *workspace = model.workspaces.find(identity);
    while (workspace != nullptr && !workspace->tabs.empty()) {
      const auto closed = removeTab(model, TabLocation{WorkspaceLocation{.id = identity}, workspace->tabs.front().id});
      for (auto *client : clients.items()) {
        if (client == nullptr || !client->connection.negotiated || client->connection.closing || client->workspace != identity) {
          continue;
        }

        try {
          publishTabClosed(*client, closed);
        } catch (...) {
          client->connection.closing = true;
        }
      }

      workspace = model.workspaces.find(identity);
    }
  }

  inline static void tabSnapshot(RuntimeModel<Memory> &model, ClientStore<Memory> &clients, std::uint64_t client_id, const RequestTabSnapshot &request) {
    const auto *workspace = model.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || (!firstPane(model.panes, *tab) && !tabHeld(clients, request.location))) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    requireClient(clients, client_id).connection.defer(request);
  }

  inline static void workspaceSnapshot(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const RequestWorkspaceSnapshot &request) {
    const auto *workspace = model.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "workspace not found"};
    }

    client.connection.defer(request);
    if (client.role == ClientRole::control && client.subscribed) {
      client.workspace = workspace->id;
    }
  }

  inline static void publishList(const RuntimeModel<Memory> &model, ClientSession<Memory> &client) {
    std::array<WorkspaceListEntry, 64> entries{};
    std::size_t count = 0;

    for (const auto *workspace : model.workspaces.items()) {
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
    for (const auto *entry : model.worktrees.items()) {
      if (entry != nullptr) {
        worktrees[worktree_count++] = entry->entry();
      }
    }

    client.connection.send(WorkspaceList{.revision = model.workspace_revision,
                                         .entries = std::span<const WorkspaceListEntry>{entries}.first(count),
                                         .worktrees = std::span{worktrees}.first(worktree_count)});
    client.workspace_revision = model.workspace_revision;
  }

  // Marks the clients viewing the workspaces changed since the last delivery for a resync.
  inline void deliverNotices(ClientStore<Memory> &clients) noexcept {
    if (overflowed_) {
      for (auto *client : clients.items()) {
        if (client != nullptr && client->workspace && client->connection.negotiated && !client->connection.closing) {
          client->workspace_resync = ResyncRequired{.workspace = {.id = *client->workspace}};
        }
      }
    }
    for (const auto &notice : std::span{notices_}.first(notice_count_)) {
      notifyWorkspaceObservers(clients, notice.workspace, notice.origin, notice.previous);
    }
    notice_count_ = 0;
    overflowed_ = false;
  }

private:
  struct Notice {
    std::uint64_t workspace = 0;
    std::uint64_t origin = 0;
    std::optional<std::uint64_t> previous;
  };

  // Queues a workspace change for the clients that view it but did not make it.
  inline void notify(std::uint64_t workspace, std::uint64_t origin, std::optional<std::uint64_t> previous = {}) noexcept {
    if (notice_count_ == notices_.size()) {
      overflowed_ = true;
      return;
    }
    notices_[notice_count_++] = {workspace, origin, previous};
  }

  inline void releaseEmptyTab(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, TabLocation location) {
    auto *workspace = model.workspaces.find(location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (tab == nullptr || !tab->panes.empty() || tabHeld(clients, location)) {
      return;
    }

    const auto closed = removeTab(model, location);
    std::array<std::uint64_t, client_capacity> viewers{};
    std::size_t count = 0;
    for (auto *client : clients.items()) {
      if (client == nullptr || !client->connection.negotiated || client->connection.closing || client->workspace != location.workspace.id) {
        continue;
      }

      try {
        publishTabClosed(*client, closed);
      } catch (...) {
        client->connection.closing = true;
      }
      viewers[count++] = client->id;
    }

    if (closed.workspace_closed) {
      for (const auto viewer : std::span{viewers}.first(count)) {
        panes.detachAll(model, clients, viewer);
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

  inline static TabClosed removeTab(RuntimeModel<Memory> &model, TabLocation location) {
    auto *workspace = model.workspaces.find(location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    const auto previous = workspace->tabs.size() == 1 ? previousWorkspace(model.workspaces, workspace->id) : std::nullopt;
    for (const auto identity : tab->panes) {
      if (auto *pane = model.panes.find(identity)) {
        pane->requestClose();
      }
    }

    std::erase_if(workspace->tabs, [&](const auto &candidate) { return candidate.id == location.tab_id; });
    const bool workspace_closed = workspace->tabs.empty();
    if (workspace_closed) {
      model.workspaces.erase(location.workspace.id);
    }

    ++model.workspace_revision;
    return TabClosed{.location = location, .workspace_closed = workspace_closed, .previous_workspace = previous};
  }

  inline void leaveEmptyViews(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t workspace) noexcept {
    for (const auto *pane : model.panes.items()) {
      if (pane != nullptr && pane->location.workspace.id == workspace && pane->exit_status) {
        return;
      }
    }

    std::array<std::uint64_t, client_capacity> viewers{};
    std::size_t count = 0;
    for (const auto *client : clients.items()) {
      if (client != nullptr && client->workspace == workspace && client->attachments.empty()) {
        viewers[count++] = client->id;
      }
    }
    for (const auto viewer : std::span{viewers}.first(count)) {
      panes.detachAll(model, clients, viewer);
    }
  }

  inline void retainFinalText(ExitedPanes &exited, Pane<Memory> &pane) noexcept {
    const auto exit_code = pane.exitCode();
    try {
      TextReader reader{memory_, pane.terminal, ExitedPanes::maximum_bytes};
      reader.read(PaneTextSource::recent, ExitedPanes::kept_rows);
      std::size_t rows = 0;
      checkGhostty(ghostty_terminal_get(pane.terminal.handle(), GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows));
      exited.record(pane.id, pane.generation, PaneText{
                                                  .truncated = reader.truncated() || rows > ExitedPanes::kept_rows,
                                                  .text = reader.text(),
                                                  .exit_code = exit_code,
                                              });
    } catch (...) {
      exited.record(pane.id, pane.generation, PaneText{.truncated = true, .exit_code = exit_code});
    }
  }

  inline std::uint64_t createRoot(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const Launch &launch, TerminalSize size, std::string_view name, bool replace_view = false) {
    if (model.next_tab_id == 0 || model.workspaces.nextCounter() == 0) {
      throw RequestError{FailureCode::resource_limit, "could not create workspace"};
    }

    const auto workspace_id = model.workspaces.nextId();
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, workspace_id, launch.cwd, name);
    const auto tab_id = model.next_tab_id;
    workspace->tabs.emplace_back(memory_, tab_id, std::string_view{});
    model.workspaces.insertProvisional(workspace_id, std::move(workspace));
    std::optional<std::uint64_t> pane;

    try {
      const TabLocation location{.workspace = {.id = workspace_id},
                                 .tab_id = tab_id};
      pane = panes.launch(model, nullptr, launch, location, size).id;
      model.workspaces.find(workspace_id)->tabs.front().panes.push_back(*pane);
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

  inline static std::uint64_t nextTabIdentity(const RuntimeModel<Memory> &model) {
    if (model.next_tab_id == 0) {
      throw RequestError{FailureCode::spawn_failed, "could not start the command"};
    }

    return model.next_tab_id;
  }

  // A pane launched into a tab whose workspace the client takes the geometry of.
  inline std::uint64_t createAt(RuntimeModel<Memory> &model, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, TabLocation location, Launch launch, TerminalSize size) {
    requireTab(model.workspaces, location);
    auto &client = requireClient(clients, client_id);
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

    const auto pane = panes.launch(model, &client.colors, launch, location, size).id;

    try {
      panes.attach(model, requireClient(clients, client_id), pane, size);
      requireTab(model.workspaces, location).panes.push_back(pane);
    } catch (...) {
      panes.remove(model, clients, pane);
      throw;
    }

    ++model.workspace_revision;
    notify(location.workspace.id, client_id);
    return pane;
  }

  inline static std::optional<std::uint64_t> firstPane(const PaneStore<Memory> &panes, const Workspace<Memory> &workspace) noexcept {
    return workspace.tabs.empty() ? std::nullopt : firstPane(panes, workspace.tabs.front());
  }

  inline static std::optional<std::uint64_t> firstPane(const PaneStore<Memory> &panes, const Tab<Memory> &tab) noexcept {
    for (const auto identity : tab.panes) {
      if (const auto *pane = panes.find(identity); pane != nullptr && !pane->close_requested && !pane->exit_status) {
        return identity;
      }
    }

    return std::nullopt;
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
  std::array<Notice, 64> notices_{};
  std::size_t notice_count_ = 0;
  bool overflowed_ = false;
};

}
}

// Interface: runtime/worktree_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorktreeService {
public:
  using Workspaces = WorkspaceService<Memory, Poller, History>;
  using Panes = PaneService<Memory, Poller, History>;

  inline explicit WorktreeService(Memory &memory, LimitService<Memory> &limits)
      : memory_(memory),
        limits_(limits) {}

  inline static void registerEntry(RuntimeModel<Memory> &model, ClientSession<Memory> &client, const RegisterWorktree &request) {
    Workspaces::require(model.workspaces, WorkspaceLocation{.id = request.source});
    if (request.created_by) {
      const auto *pane = model.panes.find(*request.created_by);
      if (client.verified_pane != *request.created_by || pane == nullptr || client.verified_generation != pane->generation) {
        throw RequestError{FailureCode::foreign_process, "Only a process inside the pane may register for it"};
      }
    }

    const auto result = model.worktrees.registerEntry(request);
    ++model.workspace_revision;
    client.connection.send(result);
  }

  inline void launch(RuntimeModel<Memory> &model, Workspaces &workspaces, Panes &panes, ClientStore<Memory> &clients, std::uint64_t client_id, const LaunchWorktree &request) {
    const auto &entry = require(model.worktrees, request.worktree);
    auto *found = entry.workspace ? model.workspaces.find(*entry.workspace) : nullptr;
    const bool created = found == nullptr;
    auto workspace = found == nullptr ? std::uint64_t{0} : found->id;
    if (created) {
      workspace = model.workspaces.nextId();
      const auto title = entry.title.view().empty() ? entry.branch.view() : entry.title.view();
      auto owned = makeOwned<Workspace<Memory>>(memory_, memory_, workspace, entry.path, utf8Prefix(title, 128));
      model.workspaces.insertProvisional(workspace, std::move(owned));
    }

    std::uint64_t pane = 0;
    try {
      auto launch = request.launch;
      LaunchDirectory directory;
      ownDirectory(launch, directory, require(model.worktrees, request.worktree).path);
      launch.cwd_source = 0;
      pane = workspaces.launchBackground(model, panes, Workspaces::ownerColors(model.workspaces, clients, workspace), LaunchTab{request.request_id, workspace, request.label, request.size, launch});
    } catch (...) {
      if (created) {
        model.workspaces.erase(workspace);
      }

      throw;
    }

    model.workspaces.advanceCounter(workspace + 1);
    auto &current = require(model.worktrees, request.worktree);
    current.workspace = workspace;
    current.command_pane = pane;
    current.command_state = CommandState::running;
    current.command_exit = 0;
    const auto program = launchedProgram(request.launch.arguments);
    current.command_label.assign(utf8Prefix(program.substr(program.rfind('/') + 1), 48));
    ++model.workspace_revision;
    const auto &launched = Panes::require(model.panes, pane);
    if (auto *client = clients.find(client_id)) {
      client->connection.send(PaneOpened{request.request_id, launched.id, launched.location, created, launched.generation});
    }
  }

  inline static void forget(RuntimeModel<Memory> &model, Workspaces &workspaces, ClientStore<Memory> &clients, std::uint64_t client_id, const ForgetWorktree &request) {
    if (const auto workspace = require(model.worktrees, request.worktree).workspace) {
      workspaces.closeWorkspace(model, clients, *workspace);
    }

    model.worktrees.remove(request.worktree);
    ++model.workspace_revision;
    if (auto *client = clients.find(client_id)) {
      client->connection.send(RequestCompleted{.request_id = request.request_id});
    }
  }

  template <typename Background>
  inline void observe(const RuntimeModel<Memory> &model, Background &background) {
    if (observing_) {
      return;
    }
    const auto now = std::chrono::steady_clock::now();
    const Worktree<Memory> *selected = nullptr;
    for (const auto *entry : model.worktrees.items()) {
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

  inline void observed(RuntimeModel<Memory> &model, const WorktreeProbeResult &result) {
    if (observing_ != result.identity) {
      return;
    }
    observing_.reset();
    auto *entry = model.worktrees.find(result.identity);
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

  inline static void refresh(RuntimeModel<Memory> &model) noexcept {
    for (auto *entry : model.worktrees.items()) {
      if (entry == nullptr) {
        continue;
      }

      if (entry->command_pane) {
        const auto *pane = model.panes.find(*entry->command_pane);
        if (pane != nullptr && pane->exit_status) {
          const auto status = *pane->exit_status;
          entry->command_exit = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
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

private:
  inline static Worktree<Memory> &require(Worktrees<Memory> &worktrees, std::uint64_t identity) {
    auto *entry = worktrees.find(identity);
    if (entry == nullptr) {
      throw RequestError{FailureCode::worktree_not_found, "worktree not found"};
    }

    return *entry;
  }

  std::optional<std::uint64_t> observing_;
  Memory &memory_;
  LimitService<Memory> &limits_;
};

}
}

// Interface: runtime/runtime.cppm
export {
namespace telar::runtime {

// The runtime owns the model, the client table and the services, and lends each service the tables
// a call needs. A request names its client by identity, and a handler looks the client up again after
// any call that can change the table, as Rust code holds an index across a mutation, not a reference.
template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
class Runtime {
  using Agents = AgentService<Memory, Poller, Background>;
  using Panes = PaneService<Memory, Poller, Background>;
  using Workspaces = WorkspaceService<Memory, Poller, Background>;
  using Worktrees = WorktreeService<Memory, Poller, Background>;
  using Control = ClientControl<Memory>;
  using Descents = DescentService<Memory, ProcessInspector>;
  using Frames = typename Connection<Memory>::Frames;

public:
  inline explicit Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {})
      : memory_(memory),
        poller_(poller),
        background_(background),
        proxy_(proxy),
        listener_(options.socket),
        model_(memory, options.graphics),
        clients_(memory),
        admissions_(poller_, limits_),
        client_layouts_(memory),
        panes_(memory, poller_, limits_, PaneLaunchOptions{options.socket, proxy, options.control_policy}, background),
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
        agent_files_(memory),
        descriptions_(memory, background_, options.descriptions),
        telemetry_(options.socket, proxy.status()) {
    model_.cli_executable = options.cli_executable;
    model_.capture_output = options.capture_output;
    model_.manifests = *options.manifests;
    agents_.enableDescriptions(descriptions_.enabled());
    if (options.fresh && !options.session.path.empty()) {
      checkpoint::FileStore<Memory>::setAside(memory, options.session.path);
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
    std::array<Event, Poller::event_capacity> ready{};
    PluginDelivery delivery{limits_};
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
      delivery.collect(clients_, plugins);
      const auto now = Clock::now();
      auto timeout = publish(now);
      TELAR_DIAGNOSTIC(model_.metrics.system = metrics_.diagnostics());
      TELAR_DIAGNOSTIC(timeout = std::min(timeout, telemetry_.tick(model_, clients_, memory_, captures, background_, Clock::now())));

      for (const auto &event : poller_.wait(timeout, ready)) {
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
        admissions_.begin(clients_.size(), std::move(descriptor));
      } catch (const std::exception &) {
        return;
      }
    }
  }

  inline void admitClient(FileDescriptor descriptor) {
    const auto identity = clients_.nextId();
    auto client = makeOwned<ClientSession<Memory>>(memory_, memory_, identity, std::move(descriptor));
    client->connection.negotiated = true;
    client->peer_identity = process_inspector_.peer(client->connection.descriptor());
    const auto handle = clients_.insert(identity, std::move(client));
    auto &admitted = requireClient(clients_, identity);
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

  inline void dropClient(std::uint64_t identity) noexcept {
    auto *client = clients_.find(identity);
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

  // Cross-client effects the services queued while a client was borrowed reach their clients before
  // the clients are written.
  inline void deliverQueued() noexcept {
    limits_.deliver(model_, clients_);
    agents_.deliverSounds(clients_);
    workspaces_.deliverNotices(clients_);
  }

  inline void clientEvent(const Event &event) {
    auto *client = clients_.findHandle(eventIdentity(event.token));
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

      if (auto *current = clients_.find(identity)) {
        updateWriteInterest(poller_, *current);
      }
    } catch (const std::exception &) {
      dropClient(identity);
    }
  }

  inline void paneEvent(const Event &event) {
    TELAR_TRACE("runtime.paneEvent");
    auto *pane = model_.panes.findHandle(eventIdentity(event.token));
    if (pane == nullptr || pane->process->descriptor() != event.descriptor) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.stale_pane_events));
      return;
    }

    const auto identity = pane->id;
    try {
      if (event.kind == EventKind::readable) {
        const auto mode = model_.panes.size() == 1 ? Pane<Memory>::ReadMode::burst : Pane<Memory>::ReadMode::once;
        if (!pane->read(mode)) {
          poller_.remove(pane->process->descriptor());
        }
      }

      panes_.flushInput(*pane);
      observations_.observe(model_, agents_, identity);
      if (auto *observed = model_.panes.find(identity)) {
        media_.updateReadInterest(*observed);
      }
    } catch (const std::exception &) {
      if (auto *failed = model_.panes.find(identity)) {
        failed->terminal.abortControl();
        failed->requestClose();
        failed->output_closed = true;
        poller_.remove(failed->process->descriptor());
      }
    }
  }

  // The client's frames leave its connection while their requests run, so a request can change any
  // client, its own included, without touching the bytes it was decoded from.
  inline void receive(std::uint64_t identity) {
    Frames frames{memory_};
    requireClient(clients_, identity).connection.exchange(frames);
    bool remaining = false;
    try {
      remaining = Connection<Memory>::dispatch(
          frames,
          [&] {
            const auto *client = clients_.find(identity);
            return client != nullptr && !client->connection.read_paused;
          },
          [&](std::span<const Byte> payload, DecodeStorage &storage) {
            if (!requireClient(clients_, identity).connection.closing) {
              dispatch(identity, payload, storage);
            }
          });
    } catch (...) {
      if (auto *client = clients_.find(identity)) {
        client->connection.exchange(frames);
      }
      throw;
    }

    if (auto *client = clients_.find(identity)) {
      client->connection.exchange(frames);
      client->connection.buffered_requests = remaining;
    }
  }

  template <typename Message>
  inline void request(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage &storage) {
    const auto message = [&] {
      TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{model_.metrics.decode});
      return Codec::decode<Message>(payload, storage);
    }();
    auto &client = requireClient(clients_, identity);
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
            auto &deferred = requireClient(clients_, identity);
            deferred_reports_.cancel(deferred);
            deferred.deferred_report.payload.clear();
            throw;
          }
          return;
        }
      }

      handle(identity, message);
    } catch (const RequestError &error) {
      if (error.code() == FailureCode::resource_limit) {
        limits_.report(LimitReach{.name = "runtime.request_capacity",
                                  .route = "request"});
      }
      fail(identity, RequestFailed{.request_id = request_id,
                                   .code = error.code(),
                                   .message = error.what()});
    } catch (const JsonError &error) {
      fail(identity, RequestFailed{.request_id = request_id,
                                   .code = FailureCode::invalid_request,
                                   .message = error.what()});
    } catch (const SystemError &error) {
      fail(identity, RequestFailed{.request_id = request_id,
                                   .code = FailureCode::spawn_failed,
                                   .message = error.what()});
    } catch (const std::bad_alloc &) {
      limits_.report(LimitReach{.name = "runtime.memory",
                                .route = "request"});
      fail(identity, RequestFailed{.request_id = request_id,
                                   .code = FailureCode::resource_limit,
                                   .message = "Runtime memory or capacity limit reached"});
    }
  }

  // A failed request answers its client unless the request dropped it.
  inline void fail(std::uint64_t identity, const RequestFailed &failure) {
    if (auto *client = clients_.find(identity)) {
      client->connection.send(failure);
    }
  }

  inline void dispatch(std::uint64_t identity, std::span<const Byte> payload, DecodeStorage &storage) {
    TELAR_TRACE("runtime.dispatch");
    TELAR_DIAGNOSTIC(diagnostics::accumulate(model_.metrics.client_messages));
    const bool recognized = dispatchRequest(static_cast<ClientTag>(payload.front()), [&]<typename Message> {
      request<Message>(identity, payload, storage);
    });

    if (!recognized) {
      throw EncodingError{"Unknown request tag"};
    }
  }

  inline void handle(std::uint64_t identity, const ReportLimit &message) {
    limits_.receive(model_.limits, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const QueryLimits &message) {
    LimitService<Memory>::query(requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const LaunchTab &message) {
    workspaces_.launchTab(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RegisterWorktree &message) {
    Worktrees::registerEntry(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const LaunchWorktree &message) {
    worktrees_.launch(model_, workspaces_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ForgetWorktree &message) {
    Worktrees::forget(model_, workspaces_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ExecutionRequest &message) {
    executions_.request(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const VerifyPaneDescent &message) {
    Descents::verify(model_.panes, requireClient(clients_, identity), message);
    descents_.schedule(clients_);
  }

  inline void handle(std::uint64_t identity, const ReportAgent &message) {
    agents_.report(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReportAgentTitle &message) {
    agents_.reportTitle(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReportAgentSession &message) {
    agents_.reportSession(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReportAgentProgress &message) {
    if (!agents_.reportProgress(model_, requireClient(clients_, identity), message)) {
      limits_.report(LimitReach{.name = "agents.max_tasks", .noun = "tasks", .value = AgentProgress::task_capacity, .requested = AgentProgress::task_capacity + 1, .route = "agents"});
    }
  }

  inline void handle(std::uint64_t identity, const InterruptAgent &message) {
    const bool focused = Agents::focused(clients_, client_layouts_, message.pane_id);
    agents_.interrupt(model_, panes_, requireClient(clients_, identity), message, focused);
  }

  inline void handle(std::uint64_t, const AcknowledgeAgent &message) {
    agents_.acknowledge(message);
  }

  inline void handle(std::uint64_t identity, const QueryAgents &) {
    requireClient(clients_, identity).agent_snapshot_requested = true;
  }

  inline void handle(std::uint64_t identity, const ReportAgentCommand &message) {
    auto &client = requireClient(clients_, identity);
    const auto &pane = agents_.validateCommand(model_, client, message);
    const auto location = pane.location;
    const auto history_session = pane.history_session;
    const auto *workspace = model_.workspaces.find(location.workspace.id);
    background_.submit(client.id, message, RequestContext{.location = location, .history_session = history_session, .workspace_path = workspace == nullptr ? std::string_view{} : std::string_view{workspace->path}, .received_at_ms = client.deferred_report.reportTime().milliseconds});
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  inline void handle(std::uint64_t identity, const FindPaths &message) {
    auto &client = requireClient(clients_, identity);
    if (!background_.tryPaths(client.id, message, client.connection)) {
      submitBackground(background_, client, message);
    }
  }

  inline void handle(std::uint64_t identity, const OpenEditor &message) {
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
        const auto process = group > 0 ? process_inspector_.identity(group) : std::nullopt;
        if (process && context.editor_candidate_count < context.editor_candidates.size()) {
          context.editor_candidates[context.editor_candidate_count++] = {pane->id, pane->generation, *process};
        }
      }
    }

    auto &client = requireClient(clients_, identity);
    submitBackground(background_, client, message, context);
    client.editor_source = source->id;
    client.editor_generation = source->generation;
  }

  inline void handle(std::uint64_t identity, const SuggestCommand &message) {
    auto &client = requireClient(clients_, identity);
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
      submitBackground(background_, client, message, RequestContext{.prompt = prompt});
    } catch (const RequestError &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    } catch (const std::bad_alloc &) {
      client.connection.send(CommandSuggestion{message.request_id, SuggestionStatus::failed});
    }
  }

  inline void handle(std::uint64_t identity, const OpenPane &message) {
    workspaces_.open(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const CreatePane &message) {
    workspaces_.createPane(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ClosePane &message) {
    Workspaces::closePane(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const CreateWorkspace &message) {
    workspaces_.createWorkspace(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RenameWorkspace &message) {
    workspaces_.renameWorkspace(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const CreateTab &message) {
    workspaces_.createTab(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RenameTab &message) {
    workspaces_.renameTab(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const CloseTab &message) {
    workspaces_.closeTab(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const HoldTab &message) {
    workspaces_.holdTab(model_, panes_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const MoveTab &message) {
    workspaces_.moveTab(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const RequestTabSnapshot &message) {
    Workspaces::tabSnapshot(model_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RequestWorkspaceSnapshot &message) {
    Workspaces::workspaceSnapshot(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const PaneInput &message) {
    panes_.input(model_, clients_, identity, message, [&agents = agents_](const Pane<Memory> &pane, std::span<const Byte> bytes) { agents.observeInput(pane, bytes); });
  }

  inline void handle(std::uint64_t identity, const PaneResize &message) {
    panes_.resize(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReadRuntimeClipboard &message) {
    runtime_clipboard_.read(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const CompleteClipboardDesktop &message) {
    if (auto *pane = ClipboardService<Memory>::complete(model_.panes, requireClient(clients_, identity), message)) {
      panes_.flushInput(*pane);
      media_.updateReadInterest(*pane);
    }
  }

  inline void handle(std::uint64_t identity, const PastePaneClipboard &message) {
    panes_.pasteClipboard(model_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ConfigurePaneDesktop &message) {
    panes_.configureDesktop(model_, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ConfigureTerminalColors &message) {
    panes_.configureColors(model_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const SearchPane &message) {
    Panes::search(model_.panes, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const CopySelection &message) {
    panes_.copySelection(model_.panes, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReadPane &message) {
    Panes::readText(requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const SendPaneText &message) {
    const bool focused = Agents::focused(clients_, client_layouts_, message.pane_id);
    agents_.sendText(model_, panes_, requireClient(clients_, identity), message, focused);
  }

  inline void handle(std::uint64_t identity, const DetachPane &message) {
    panes_.detach(model_, clients_, identity, message.pane_id);
  }

  inline void handle(std::uint64_t identity, const FrameAck &message) {
    if (auto *attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->frames.acknowledge(message.frame_id);
    }
  }

  inline void handle(std::uint64_t identity, const RequestSnapshot &message) {
    if (auto *attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->frames.requestSnapshot();
    }
  }

  inline void handle(std::uint64_t identity, const SetPaneViewport &message) {
    if (auto *attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->viewport = message.offset;
      attachment->frames.requestSnapshot();
    }
  }

  inline void handle(std::uint64_t identity, const ConfigureFrameInterval &message) {
    requireClient(clients_, identity).frame_interval = std::chrono::nanoseconds{message.interval_ns};
  }

  inline void handle(std::uint64_t identity, const RequestRuntimeState &message) {
    auto &client = requireClient(clients_, identity);
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

  inline void handle(std::uint64_t identity, const QueryClients &message) {
    Control::list(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const DetachClient &message) {
    Control::detach(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RequestClientCommand &message) {
    Control::requestCommand(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const CompleteClientCommand &message) {
    Control::completeCommand(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const RequestPaneFocus &message) {
    Control::requestFocus(model_.panes, clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const CompletePaneFocus &message) {
    Control::completeFocus(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const ShowNotification &message) {
    Control::notify(clients_, identity, message);
  }

  inline void handle(std::uint64_t identity, const UpdateClientLayout &message) {
    client_layouts_.retain(model_, requireClient(clients_, identity).identity, message);
  }

  inline void handle(std::uint64_t identity, const QueryHistory &message) {
    auto &client = requireClient(clients_, identity);
    submitBackground(background_, client, message, RequestContext{.persistent_client = client.role == ClientRole::interactive});
  }

  inline void handle(std::uint64_t identity, const ImportHistory &message) {
    auto &client = requireClient(clients_, identity);
    submitBackground(background_, client, message);
    client.connection.send(RequestCompleted{.request_id = message.request_id});
  }

  inline void handle(std::uint64_t identity, const DeleteHistory &message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const PruneHistory &message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ReadHistoryOutput &message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const HistoryStatsQuery &message) {
    submitBackground(background_, requireClient(clients_, identity), message);
  }

  inline void handle(std::uint64_t identity, const ConfigureGraphics &message) {
    auto &client = requireClient(clients_, identity);
    client.shared_graphics = message.shared;
    for (auto &attachment : client.attachments) {
      attachment->graphics.configure(message.shared);
    }
  }

  inline void handle(std::uint64_t identity, const GraphicsCredit &message) {
    if (auto *attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->graphics.returnCredit(message.bytes);
    }
  }

  inline void handle(std::uint64_t identity, const RequestGraphicsSnapshot &message) {
    if (auto *attachment = requireClient(clients_, identity).attachment(message.pane_id)) {
      attachment->graphics.requestSnapshot();
    }
  }

  inline void handle(std::uint64_t, const RuntimeStop &) {
    model_.stopping = true;
  }

  template <typename Message>
  inline static void submitBackground(Background &background, const ClientSession<Memory> &client, const Message &message, RequestContext context = {}) {
    if constexpr (std::same_as<Message, OpenEditor>) {
      if (client.editor_source != 0) {
        throw RequestError{FailureCode::resource_limit, "An editor request is already pending"};
      }
    }

    background.submit(client.id, message, context);
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

  inline void collectBackground() {
    TELAR_TRACE("runtime.collectBackground");
    session_.collect();
    observations_.collect(model_, agents_);
    media_.collect(model_, clients_, panes_);
    descents_.collect(clients_, model_.panes);
    answerDeferredReports();
    metrics_.collect();
    runtime_clipboard_.collect(clients_);
    workspace_git_.collect(model_, Clock::now());
    worktree_detection_.collect(model_);
    agent_files_.collect(agents_);
    descriptions_.collect(agents_);
    if (const auto failures = background_.takeHistoryFailures()) {
      limits_.report(LimitReach{.name = "history.command_persistence", .noun = "failed events", .requested = failures, .route = "history"});
    }
    background_.collectWorktrees([&](const WorktreeProbeResult &result) { worktrees_.observed(model_, result); });
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

      auto *client = clients_.find(client_id);
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
        updateWriteInterest(poller_, *client);
      } catch (...) {
        dropClient(client_id);
      }
    });
  }

  inline std::chrono::nanoseconds publish(Clock::time_point now) {
    TELAR_TRACE("runtime.publish");
    admissions_.expire(now);
    runtime_clipboard_.expire(clients_, now);
    media_.collect(model_, clients_, panes_);
    std::chrono::nanoseconds timeout = std::chrono::milliseconds{100};
    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        try {
          if (ClipboardService<Memory>::advance(clients_, *pane, now) && !pane->output_closed) {
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
    } catch (const std::bad_alloc &) {
    } catch (const RequestError &) {
    }

    Worktrees::refresh(model_);
    worktrees_.observe(model_, background_);
    workspaces_.collectExited(model_, panes_, clients_);
    timeout = std::min(timeout, session_.tick(model_, client_layouts_, agents_, now));
    timeout = std::min(timeout, metrics_.tick(now));
    timeout = std::min(timeout, workspace_git_.tick(model_, now));
    deliverQueued();

    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {
      const auto *listed = clients_.items()[slot];
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
          auto &closing = requireClient(clients_, identity);
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
      } catch (const std::exception &) {
        dropClient(identity);
      }
    }

    media_.start(model_, clients_, panes_);
    return timeout;
  }

  inline std::chrono::nanoseconds writeClient(std::uint64_t identity, Clock::time_point now) {
    StateProjection state{workspaces_, agents_, metrics_, client_layouts_, proxy_};
    const auto result = ClientDelivery{memory_, model_}.write(requireClient(clients_, identity), state, now);
    if (result.detach_pane) {
      panes_.release(model_, clients_, identity, *result.detach_pane);
    }
    return result.timeout;
  }

  inline static void updateWriteInterest(Poller &poller, ClientSession<Memory> &client) {
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

  // A due report runs as its client's next request, its payload and the client's frames held apart
  // from the client meanwhile.
  inline void answerDeferredReports() {
    const auto due = deferred_reports_.due(clients_, model_.panes, agents_, ObservationTime::now());
    for (const auto identity : due.ids()) {
      auto *client = clients_.find(identity);
      if (client == nullptr) {
        continue;
      }

      Vector<Byte, Memory> payload{AllocatorRef<Byte, Memory>{memory_}};
      deferred_reports_.open(*client, payload);
      Frames frames{memory_};
      client->connection.exchange(frames);
      bool answered = false;
      try {
        if (!client->connection.closing) {
          DecodeStorage storage{frames.decode};
          dispatch(identity, std::span<const Byte>{payload}, storage);
          answered = true;
        }
      } catch (...) {
        if (auto *failed = clients_.find(identity)) {
          failed->connection.closeImmediately();
        }
      }

      if (auto *current = clients_.find(identity)) {
        current->connection.exchange(frames);
        DeferredReports<Memory, Agents>::close(*current, payload);
        if (answered) {
          updateWriteInterest(poller_, *current);
        }
      }
    }
  }

  inline void stop() noexcept {
    admissions_.clear();
    session_.finish(model_, client_layouts_, agents_);
    for (std::size_t slot = 0; slot < clients_.items().size(); ++slot) {
      auto *client = clients_.items()[slot];
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

    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        pane->process->signal(SIGTERM);
        pane->observer->finishSession();
      }
    }

    observations_.finish(model_);
    media_.finish(model_);
  }

  Memory &memory_;
  Poller &poller_;
  Background &background_;
  ProxyClientConfiguration proxy_;
  LocalListener listener_;
  RuntimeModel<Memory> model_;
  ClientStore<Memory> clients_;
  LimitService<Memory> limits_;
  RuntimeClipboardService<Memory> runtime_clipboard_;
  ClientAdmission<Memory, Poller> admissions_;
  ClientLayouts<Memory> client_layouts_;
  Panes panes_;
  Workspaces workspaces_;
  Worktrees worktrees_;
  ExecutionService<Memory, Poller> executions_;
  ProcessInspector process_inspector_;
  Agents agents_;
  ProcessProbe<ProcessInspector> process_probe_;
  PaneObservationService<Memory, Agents, LimitService<Memory>, ProcessProbe<ProcessInspector>, Background> observations_;
  MediaService<Memory, Poller, LimitService<Memory>, Background> media_;
  DeferredReports<Memory, Agents> deferred_reports_;
  Descents descents_;
  checkpoint::SessionStore<Memory, Poller, Agents, Background> session_;
  HostMetricsService<NativeHostMetrics> metrics_;
  WorkspaceGitService<Memory, WorkspaceGitProbe<Memory>> workspace_git_;
  WorktreeDetectionService<Memory, WorktreeDetectionProbe> worktree_detection_;
  AgentFileService<Memory, Agents> agent_files_;
  DescriptionService<Memory, Agents, Background> descriptions_;
  [[no_unique_address]] diagnostics::RuntimeTelemetry telemetry_;
};

template <ConcurrentAllocator Memory, EventLoop Poller, typename Background>
  requires BackgroundExecutor<Background, Memory>
Runtime(Memory &memory, Poller &poller, Background &background, const RuntimeOptions &options, ProxyClientConfiguration proxy = {}) -> Runtime<Memory, Poller, Background>;

}
}
