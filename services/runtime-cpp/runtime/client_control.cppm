module;
#include <new>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <sqlite3.h>
#include <cstdint>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>

#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>

#include <clipboard.hpp>

export module telar.runtime.runtime.client_control;

import std;

export import telar.runtime.agents.snapshot;
export import telar.runtime.platform.request_worker;


export import telar.runtime.model.client_layouts;
export import telar.client;


export import telar.runtime.platform.process_probe;


export import telar.runtime.metrics.host_sampler;


export import telar.runtime.observation.processor;


export import telar.runtime.worktrees.git_probe;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: runtime/agent_file_service.cppm
export {
namespace telar::runtime {

template <typename Agents>
concept SessionFileObserver = requires(Agents &agents, const SessionFileResult &result, std::chrono::steady_clock::time_point now) {
  { agents.nextSessionFile(now) } -> std::same_as<std::optional<SessionFileRequest>>;
  { agents.completeSessionFile(result, now) } -> std::same_as<void>;
};

// Reads agents' session files on a worker; the agents are lent to each call.
template <ConcurrentAllocator Memory, SessionFileObserver Agents>
class AgentFileService {
public:
  inline explicit AgentFileService(Memory &memory)
      : worker_(std::in_place, memory) {}

  inline void tick(Agents &agents, std::chrono::steady_clock::time_point now) {
    collect(agents);
    if (!pending_) {
      if (const auto request = agents.nextSessionFile(now)) {
        pending_ = worker_.submit(*request);
      }
    }
  }

  inline void collect(Agents &agents) {
    if (!pending_) {
      return;
    }

    worker_.collect([&](const SessionFileResult &result) {
      pending_ = false;
      agents.completeSessionFile(result, std::chrono::steady_clock::now());
    });
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  ObservationWorker<SessionFileReader<Memory>> worker_;
  bool pending_ = false;
};

}
}

// Interface: runtime/client_control.cppm
export {
namespace telar::runtime {

// Requests between clients. Each call is given the client table and the requester's identity, and
// looks up the clients it reaches, as two elements of one Rust map are borrowed one after the other.
template <Allocator Memory>
class ClientControl {
public:
  inline static void list(ClientStore<Memory> &clients, std::uint64_t requester_id, const QueryClients &request) {
    std::array<ClientDescriptor, client_capacity> entries;
    std::size_t count = 0;

    for (const auto *client : clients.items()) {
      if (!routable(client)) {
        continue;
      }

      entries[count++] = ClientDescriptor{
          .id = client->id,
          .generation = client->generation,
          .identity = client->identity,
          .attachments = static_cast<std::uint16_t>(client->attachments.size()),
          .last_input_pane = client->last_input_pane,
          .last_input_sequence = client->last_input_sequence,
      };
    }

    requireClient(clients, requester_id).connection.send(ClientList{.request_id = request.request_id,
                                                            .entries = std::span{entries}.first(count)});
  }

  inline static void detach(ClientStore<Memory> &clients, std::uint64_t requester_id, const DetachClient &request) {
    auto &requester = requireClient(clients, requester_id);
    requireRole(requester, ClientRole::control);
    auto *target = resolve(clients, ClientRoute{request.client_id, request.client_generation});
    if (!routable(target) || target == &requester) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    requester.connection.send(RequestCompleted{.request_id = request.request_id});
    target->connection.closing = true;
  }

  inline static void requestCommand(ClientStore<Memory> &clients, std::uint64_t requester_id, const RequestClientCommand &request) {
    auto &requester = requireClient(clients, requester_id);
    requireRole(requester, ClientRole::control);
    if (request.status != ClientCommandStatus::request || requester.pending_command) {
      throw RequestError{FailureCode::invalid_request, "Invalid or already pending client command"};
    }

    auto *target = resolve(clients, request.route);
    if (!routable(target)) {
      throw RequestError{FailureCode::invalid_request, "Interactive client is absent, closing, or stale"};
    }

    ClientCommand forwarded = request;
    forwarded.route = route(requester);
    try {
      target->connection.send(forwarded);
    } catch (const ResponseQueueFull &) {
      throw RequestError{FailureCode::invalid_request, "ResponseQueueFull"};
    }
    requester.pending_command = PendingClientCommand{target->id, request.request_id, request.action, request.target_id};
  }

  inline static void completeCommand(ClientStore<Memory> &clients, std::uint64_t sender_id, const CompleteClientCommand &completion) {
    const auto &sender = requireClient(clients, sender_id);
    requireRole(sender, ClientRole::interactive);
    auto *requester = resolve(clients, completion.route);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_command) {
      return;
    }

    const auto &pending = *requester->pending_command;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.action != completion.action || pending.target_id != completion.target_id || completion.status == ClientCommandStatus::request) {
      return;
    }

    ClientCommandResult result;
    static_cast<ClientCommand &>(result) = completion;
    result.route = route(sender);
    requester->connection.send(result);
    requester->pending_command.reset();
  }

  inline static void requestFocus(const PaneStore<Memory> &panes, ClientStore<Memory> &clients, std::uint64_t requester_id, const RequestPaneFocus &request) {
    auto &requester = requireClient(clients, requester_id);
    requireRole(requester, ClientRole::control);
    const auto *pane = panes.find(request.pane_id);
    if (pane == nullptr || pane->generation != request.pane_generation) {
      throw RequestError{FailureCode::pane_not_found, "Pane does not exist or its generation is stale"};
    }

    if (pane->exit_status) {
      throw RequestError{FailureCode::pane_exited, "Pane already exited"};
    }

    if (requester.pending_focus) {
      throw RequestError{FailureCode::invalid_request, "A pane focus request is already pending"};
    }

    auto *target = focusOrigin(clients, pane->id);
    if (target == nullptr) {
      throw RequestError{FailureCode::invalid_request, "No interactive client originated input for this pane"};
    }

    target->connection.send(PaneFocusCommand{
        .requester = route(requester),
        .request_id = request.request_id,
        .pane_id = pane->id,
        .pane_generation = pane->generation,
        .direction = request.direction,
    });
    requester.pending_focus = PendingPaneFocus{target->id, request.request_id, pane->id, pane->generation};
  }

  inline static void completeFocus(ClientStore<Memory> &clients, std::uint64_t sender_id, const CompletePaneFocus &completion) {
    const auto &sender = requireClient(clients, sender_id);
    requireRole(sender, ClientRole::interactive);
    auto *requester = resolve(clients, completion.requester);
    if (requester == nullptr || requester->connection.closing || requester->role != ClientRole::control || !requester->pending_focus) {
      return;
    }

    const auto &pending = *requester->pending_focus;
    if (pending.target != sender.id || pending.request_id != completion.request_id || pending.pane_id != completion.pane_id || pending.pane_generation != completion.pane_generation) {
      return;
    }

    requester->connection.send(PaneFocusResult{.request_id = completion.request_id,
                                               .outcome = completion.outcome,
                                               .focused_pane_id = completion.focused_pane_id});
    requester->pending_focus.reset();
    requester->connection.closing = true;
  }

  // Shows a notification on the interactive clients and tells the requester how many received it. The
  // confirmation takes its place in the requester's queue first, so a full queue refuses the request
  // before anything is shown; its count is filled in by offset once the clients are reached.
  inline static void notify(ClientStore<Memory> &clients, std::uint64_t requester_id, const ShowNotification &request) {
    NotificationShown confirmation{.request_id = request.request_id};
    const auto offset = requireClient(clients, requester_id).connection.reserve(confirmation);
    confirmation.delivered_clients = publish(clients, request.notification);
    requireClient(clients, requester_id).connection.complete(offset, confirmation);
  }

  inline static std::uint8_t publish(ClientStore<Memory> &clients, const NotificationBody &body) {
    std::uint8_t delivered = 0;
    Notification notification;
    static_cast<NotificationBody &>(notification) = body;

    for (auto *client : clients.items()) {
      if (client == nullptr || client->connection.closing || client->role != ClientRole::interactive) {
        continue;
      }

      try {
        delivered += client->connection.trySend(notification);
      } catch (const std::bad_alloc &) {
      }
    }

    return delivered;
  }

  inline static void abandon(ClientStore<Memory> &clients, std::uint64_t departed) noexcept {
    for (auto *client : clients.items()) {
      if (client == nullptr || client->id == departed) {
        continue;
      }

      if (client->pending_command && client->pending_command->target == departed) {
        failAbandoned(*client, client->pending_command->request_id);
        client->pending_command.reset();
      }

      if (client->pending_focus && client->pending_focus->target == departed) {
        failAbandoned(*client, client->pending_focus->request_id);
        client->pending_focus.reset();
        client->connection.closing = true;
      }
    }
  }

private:
  inline static void requireRole(const ClientSession<Memory> &client, ClientRole expected) {
    if (client.role != expected) {
      throw RequestError{FailureCode::invalid_request, "Invalid client role"};
    }
  }

  inline static bool routable(const ClientSession<Memory> *client) noexcept {
    return client != nullptr && !client->connection.closing && client->role == ClientRole::interactive && client->identity != 0;
  }

  inline static ClientSession<Memory> *resolve(ClientStore<Memory> &clients, ClientRoute target) noexcept {
    auto *client = clients.find(target.id);
    return client != nullptr && client->generation == target.generation ? client : nullptr;
  }

  inline static ClientRoute route(const ClientSession<Memory> &client) noexcept {
    return ClientRoute{client.id, client.generation};
  }

  inline static ClientSession<Memory> *focusOrigin(ClientStore<Memory> &clients, std::uint64_t pane_id) noexcept {
    ClientSession<Memory> *selected = nullptr;
    for (auto *client : clients.items()) {
      if (client == nullptr || client->connection.closing || client->role != ClientRole::interactive || client->last_input_pane != pane_id || client->attachment(pane_id) == nullptr || client->last_input_sequence == 0) {
        continue;
      }

      if (selected == nullptr || client->last_input_sequence > selected->last_input_sequence) {
        selected = client;
      }
    }

    return selected;
  }

  inline static void failAbandoned(ClientSession<Memory> &client, std::uint64_t request_id) noexcept {
    try {
      client.connection.send(RequestFailed{.request_id = request_id,
                                           .code = FailureCode::invalid_request,
                                           .message = "Target client disconnected before confirming the operation"});
    } catch (...) {
      client.connection.closeImmediately();
    }
  }

};

}
}

// Interface: runtime/deferred_reports.cppm
export {
namespace telar::runtime {

enum class ReportDecision {
  accepted,
  deferred,
  rejected
};

template <typename Message>
std::optional<ReporterIdentity> reporterOf(const AgentManifests &manifests, const Message &message) noexcept {
  if constexpr (std::same_as<Message, ReportAgent> || std::same_as<Message, ReportAgentTitle> || std::same_as<Message, ReportAgentProgress>) {
    return ReporterIdentity{message.pane_id, message.pane_generation, message.provider};
  } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
    return ReporterIdentity{message.pane_id, message.pane_generation, manifests.named(message.provider)};
  } else {
    return std::nullopt;
  }
}

template <typename Agents>
concept ReporterAgents = requires(const Agents &agents, std::uint64_t pane, std::uint64_t generation) {
  { agents.find(pane, generation) } -> std::convertible_to<const Agent *>;
};

// Holds a report back until the pane's process is checked again. A held report keeps its payload in
// its client; the runtime takes it out to replay it.
template <Allocator Memory, ReporterAgents Agents>
class DeferredReports {
public:
  // The clients whose held reports are due, in the order they were held.
  struct Due {
    std::array<std::uint64_t, client_capacity> clients{};
    std::size_t count = 0;

    inline std::span<const std::uint64_t> ids() const noexcept {
      return std::span{clients}.first(count);
    }
  };

  inline ReportDecision evaluate(PaneStore<Memory> &panes, const Agents &agents, ClientSession<Memory> &client, ReporterIdentity reporter, std::span<const Byte> payload) {
    if (reporter.provider == AgentProvider::unknown) {
      return ReportDecision::accepted;
    }

    auto *pane = panes.find(reporter.pane);
    if (pane == nullptr || pane->generation != reporter.generation || pane->exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    if (client.verified_pane != pane->id || client.verified_generation != pane->generation) {
      throw RequestError{FailureCode::foreign_process, "The report does not come from this pane's agent"};
    }
    if (accepts(agents, reporter)) {
      return ReportDecision::accepted;
    }

    auto &report = client.deferred_report;
    const auto rejection = reportingRejection(agents, client, *pane);
    if (report.answering) {
      if (report.answer_rechecked && rejection) {
        pane->rejected_reporter = rejection;
      }
      return ReportDecision::rejected;
    }
    if (rejection && pane->rejected_reporter == rejection) {
      return ReportDecision::rejected;
    }

    report.payload.assign(payload.begin(), payload.end());
    report.reporter = reporter;
    report.required_recheck = pane->process_rechecks + (pane->process_recheck_running ? 2 : 1);
    report.observed = ObservationTime::now();
    report.sequence = ++sequence_;
    report.pending = true;
    client.connection.read_paused = true;
    pane->process_recheck_requested = true;
    ++pending_;
    return ReportDecision::deferred;
  }

  inline void cancel(ClientSession<Memory> &client) noexcept {
    if (client.deferred_report.pending) {
      client.deferred_report.pending = false;
      client.connection.read_paused = false;
      --pending_;
    }
  }

  // Marks whether each due report's process was checked again.
  inline Due due(ClientStore<Memory> &clients, const PaneStore<Memory> &panes, const Agents &agents, ObservationTime now) const {
    Due due;
    if (pending_ == 0) {
      return due;
    }

    std::array<const ClientSession<Memory> *, client_capacity> ready;
    for (auto *client : clients.items()) {
      if (client == nullptr || !client->deferred_report.pending) {
        continue;
      }

      auto &report = client->deferred_report;
      const auto *pane = panes.find(report.reporter.pane);
      const bool gone = pane == nullptr || pane->generation != report.reporter.generation || pane->exit_status;
      const bool timed_out = now.nanoseconds - report.observed.nanoseconds >= report_timeout.count();
      const bool rechecked = !gone && report.rechecked(pane->process_rechecks);
      const bool accepted = !gone && accepts(agents, report.reporter);
      if (gone || timed_out || rechecked || accepted) {
        report.answer_rechecked = rechecked || accepted;
        ready[due.count++] = client;
      }
    }

    auto ordered = std::span{ready}.first(due.count);
    std::ranges::sort(ordered, [](const auto *left, const auto *right) {
      return std::bit_cast<std::int64_t>(left->deferred_report.sequence - right->deferred_report.sequence) < 0;
    });
    for (std::size_t index = 0; index < due.count; ++index) {
      due.clients[index] = ordered[index]->id;
    }
    return due;
  }

  // Releases a due report to be answered and exchanges its payload with the caller's empty one, which
  // must share the client's allocator, as Rust's `mem::swap`.
  inline void open(ClientSession<Memory> &client, Vector<Byte, Memory> &payload) noexcept {
    cancel(client);
    client.deferred_report.answering = true;
    client.connection.read_paused = false;
    payload.swap(client.deferred_report.payload);
  }

  // Ends the answer and gives the payload's storage back to the client.
  inline static void close(ClientSession<Memory> &client, Vector<Byte, Memory> &payload) noexcept {
    payload.clear();
    payload.swap(client.deferred_report.payload);
    client.deferred_report.answering = false;
  }

private:
  inline static bool accepts(const Agents &agents, ReporterIdentity reporter) noexcept {
    const auto *agent = agents.find(reporter.pane, reporter.generation);
    return agent == nullptr || agent->evidence.accepts(reporter.provider);
  }

  inline static std::optional<RejectedReporter> reportingRejection(const Agents &agents, const ClientSession<Memory> &client, const Pane<Memory> &pane) noexcept {
    const auto *agent = agents.find(pane.id, pane.generation);
    if (agent == nullptr || !agent->agent_identity || !agent->process_identity) {
      return std::nullopt;
    }

    const auto group = agent->process_identity->pid;
    const auto member = agent->agent_identity->pid;
    const auto root = pane.process->processId();
    const auto lineage = client.verified_lineage.ancestors();
    for (std::size_t index = 0; index < lineage.size(); ++index) {
      if (lineage[index] != member && lineage[index] != group && lineage[index] != root) {
        continue;
      }
      if (index == 0 || lineage[index - 1] == member || lineage[index - 1] == group) {
        return std::nullopt;
      }

      return RejectedReporter{group, member, lineage[index - 1]};
    }

    return std::nullopt;
  }

  static constexpr std::chrono::nanoseconds report_timeout = std::chrono::seconds{2};
  std::uint64_t sequence_ = 0;
  std::size_t pending_ = 0;
};

}
}

// Interface: runtime/descent_service.cppm
export {
namespace telar::runtime {

// Checks on a worker that a client's process descends from a pane. A request is held in its client
// until the caller schedules the held checks.
template <ConcurrentAllocator Memory, LineageInspector Inspector>
class DescentService {
public:
  inline explicit DescentService(const Inspector &inspector)
      : worker_(std::in_place, inspector) {}

  inline static void verify(const PaneStore<Memory> &panes, ClientSession<Memory> &client, const VerifyPaneDescent &request) {
    const auto *pane = panes.find(request.pane_id);
    if (pane == nullptr || request.pane_generation == 0 || pane->generation != request.pane_generation || pane->exit_status) {
      throw RequestError{FailureCode::pane_not_found, "Pane not found"};
    }
    if (client.pending_descent) {
      throw RequestError{FailureCode::resource_limit, "A descent verification is already pending"};
    }

    client.verified_pane = 0;
    client.verified_generation = 0;
    client.verified_lineage = {};
    if (!client.peer_identity || pane->process->processId() <= 0) {
      throw RequestError{FailureCode::foreign_process, "The process does not descend from this pane"};
    }

    client.pending_descent = DescentCheck{client.id, client.generation, pane->id, pane->generation, request.request_id, *client.peer_identity, pane->process->processId()};
    client.connection.read_paused = true;
  }

  inline void collect(ClientStore<Memory> &clients, const PaneStore<Memory> &panes) {
    if (!pending_) {
      return;
    }

    worker_.collect([&](const typename DescentProbe<Inspector>::Result &result) {
      pending_ = false;
      for (const auto &completed : std::span{result.checks}.first(result.count)) {
        finish(clients, panes, completed);
      }
    });
    schedule(clients);
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

  // Submits the held checks no worker runs yet.
  inline void schedule(ClientStore<Memory> &clients) {
    if (pending_) {
      return;
    }

    typename DescentProbe<Inspector>::Request request;
    for (auto *client : clients.items()) {
      if (client != nullptr && client->pending_descent && !client->descent_running && !client->connection.closing) {
        request.checks[request.count++] = *client->pending_descent;
      }
    }
    if (request.count == 0 || !worker_.submit(request)) {
      return;
    }

    pending_ = true;
    for (const auto &check : std::span{request.checks}.first(request.count)) {
      clients.find(check.client)->descent_running = true;
    }
  }

private:
  inline static void finish(ClientStore<Memory> &clients, const PaneStore<Memory> &panes, const typename DescentProbe<Inspector>::Completion &completed) noexcept {
    const auto &check = completed.check;
    auto *client = clients.find(check.client);
    if (client == nullptr || client->generation != check.client_generation) {
      return;
    }

    client->pending_descent.reset();
    client->descent_running = false;
    client->connection.read_paused = false;
    if (client->connection.closing) {
      return;
    }

    try {
      const auto *pane = panes.find(check.pane);
      if (pane == nullptr || pane->generation != check.pane_generation || pane->exit_status) {
        client->connection.send(RequestFailed{.request_id = check.request_id, .code = FailureCode::pane_not_found, .message = "Pane not found"});
      } else if (!completed.lineage.descends) {
        client->connection.send(RequestFailed{.request_id = check.request_id, .code = FailureCode::foreign_process, .message = "The process does not descend from this pane"});
      } else {
        client->verified_pane = pane->id;
        client->verified_generation = pane->generation;
        client->verified_lineage = completed.lineage;
        client->connection.send(RequestCompleted{.request_id = check.request_id});
      }
    } catch (...) {
      client->connection.closing = true;
    }
  }

  ObservationWorker<DescentProbe<Inspector>> worker_;
  bool pending_ = false;
};

}
}

// Interface: runtime/metrics_service.cppm
export {
namespace telar::runtime {

// Samples the host on the metrics worker. It owns its probe, built from the arguments; a reference
// type as `Probe` lends one instead.
template <typename Probe>
  requires HostMetricsProbe<std::remove_reference_t<Probe>>
class HostMetricsReader {
public:
  using Request = HostSampler;
  using Result = HostSampler;

  template <typename... Arguments>
  inline explicit HostMetricsReader(Arguments &&...probe) noexcept
      : probe_(std::forward<Arguments>(probe)...) {}

  inline Result observe(const Request &previous) noexcept {
    auto next = previous;
    TELAR_DIAGNOSTIC(const auto started = std::chrono::steady_clock::now());
    if (const auto counters = probe_.read()) {
      next.apply(*counters);
    }

    TELAR_DIAGNOSTIC(next.recordSample(started, std::chrono::steady_clock::now()));

    return next;
  }

  inline void stop() noexcept {}

private:
  Probe probe_;
};

template <typename Probe>
  requires HostMetricsProbe<std::remove_reference_t<Probe>>
class HostMetricsService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto sample_interval = std::chrono::seconds{2};

  template <typename... Arguments>
  inline explicit HostMetricsService(Clock::time_point started, Arguments &&...probe)
      : worker_(std::in_place, std::forward<Arguments>(probe)...),
        next_sample_(started + sample_interval) {}

  inline std::chrono::nanoseconds tick(Clock::time_point now) {
    collect();
    if (now >= next_sample_) {
      next_sample_ = now + sample_interval;
      worker_.submit(sampler_);
    }

    return next_sample_ - now;
  }

  inline void collect() {
    worker_.collect([this](const HostSampler &sample) { sampler_ = sample; });
  }

  template <Allocator Memory>
  inline void publish(ClientSession<Memory> &client) const {
    if (!client.subscribed || client.metrics_revision == sampler_.revision()) {
      return;
    }

    if (const auto &values = sampler_.latest()) {
      client.connection.send(SystemMetrics{
          .revision = sampler_.revision(),
          .cpu_percent = values->cpu_percent,
          .memory_used_decigib = values->memory_used_decigib,
          .has_battery = values->battery_percent.has_value(),
          .battery_percent = values->battery_percent.value_or(0),
          .cpu_count = values->cpu_count,
          .memory_total_decigib = values->memory_total_decigib,
      });
    }

    client.metrics_revision = sampler_.revision();
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

#if TELAR_DIAGNOSTICS
  inline const diagnostics::SystemCounters &diagnostics() const noexcept {
    return sampler_.diagnostics();
  }
#endif

private:
  ObservationWorker<HostMetricsReader<Probe>> worker_;
  HostSampler sampler_;
  Clock::time_point next_sample_;
};

}
}

// Interface: runtime/observation_service.cppm
export {
namespace telar::runtime {

template <typename Agents, typename Memory>
concept AgentObservationSink = Allocator<Memory> && requires(Agents &agents, Pane<Memory> &pane, AgentSignal signal, ObservationTime time) {
  { agents.find(pane.id, pane.generation) } -> std::convertible_to<const Agent *>;
  { agents.observeScreen(pane, signal, time) } -> std::same_as<void>;
  { agents.observeProcess(pane, ProcessProbeResult{}) } -> std::same_as<void>;
};

template <typename Limits>
concept ObservationLimitSink = requires(Limits &limits, const LimitReach &reach) {
  { limits.report(reach) } -> std::same_as<void>;
};

// Observes pane screens and processes on a worker. The model and the agents are lent to each call.
template <ConcurrentAllocator Memory, typename Agents, ObservationLimitSink Limits, PaneProcessProbe Probe, HistoryEventSink History>
  requires AgentObservationSink<Agents, Memory>
class PaneObservationService {
  using Processor = ObservationProcessor<Memory, Probe, History>;

public:
  inline explicit PaneObservationService(Limits &limits, const AgentManifests &manifests, Probe &probe, History &history)
      : limits_(limits),
        worker_(std::in_place, manifests, probe, history) {}

  inline void refresh(RuntimeModel<Memory> &model, Agents &agents) {
    collect(model, agents);
    if (pending_) {
      return;
    }

    typename Processor::Request request;
    enqueueRetired(model, request);
    const auto panes = model.panes.items();
    const bool sole = model.panes.size() == 1;
    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      const auto slot = next_slot_++ % panes.size();
      auto *pane = panes[slot];
      if (pane == nullptr) {
        continue;
      }

      enqueue(request, agents, *pane, sole);
      if (request.count == request.entries.size()) {
        break;
      }
    }

    if (request.count != 0) {
      pending_ = worker_.submit(request);
    }
  }

  inline void observe(RuntimeModel<Memory> &model, Agents &agents, std::uint64_t pane_id) {
    collect(model, agents);
    auto *pane = model.panes.find(pane_id);
    if (pending_ || pane == nullptr) {
      return;
    }

    typename Processor::Request request;
    enqueue(request, agents, *pane, model.panes.size() == 1);
    if (request.count != 0) {
      pending_ = worker_.submit(request);
    }
  }

  inline void collect(RuntimeModel<Memory> &model, Agents &agents) {
    if (!pending_) {
      return;
    }

    worker_.collect([&](const typename Processor::Result &result) { apply(model, agents, result); });
  }

  inline void finish(RuntimeModel<Memory> &model) noexcept {
    for (;;) {
      worker_.wait([&](const typename Processor::Result &result) {
        pending_ = false;
        for (const auto &entry : std::span{result.entries}.first(result.count)) {
          entry.observer->complete();
        }
      });

      typename Processor::Request request;
      for (auto *pane : model.panes.items()) {
        if (pane != nullptr && pane->observer->seal()) {
          request.entries[request.count++].observer = pane->observer;
          if (request.count == request.entries.size()) {
            break;
          }
        }
      }

      enqueueRetired(model, request);
      if (request.count == 0) {
        return;
      }

      pending_ = worker_.submit(request);
    }
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  inline void apply(RuntimeModel<Memory> &model, Agents &agents, const typename Processor::Result &result) {
    pending_ = false;
    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      entry.observer->complete();
    }

    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      TELAR_DIAGNOSTIC(model.metrics.observation.merge(entry.screen.metrics));
      if (entry.screen.failed) {
        limits_.report(LimitReach{.name = "history.observation_failures", .noun = "failed observations", .route = "history"});
      }

      auto *pane = model.panes.find(entry.pane);
      if (pane == nullptr || pane->generation != entry.generation || pane->exit_status) {
        continue;
      }

      if (entry.process_recheck) {
        pane->process_recheck_running = false;
        ++pane->process_rechecks;
      }

      pane->shell_markers = entry.screen.shell_markers && !entry.screen.failed;
      if (pane->input_revision == entry.input_revision) {
        pane->needs_foreground_observation = entry.screen.needs_foreground;
      }
      const auto directory = entry.observer->observedDirectory();
      if (pane->cwd_revision == entry.cwd_revision && !directory.empty() && pane->cwd != directory) {
        pane->cwd.assign(directory);
        ++pane->cwd_revision;
      }

      if (entry.process_result && entry.process_result->inspected) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_inspections));
        TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_misses, entry.process_result->provider == AgentProvider::unknown));
        applyProcess(agents, *pane, *entry.process_result);
      }

      if (entry.screen.signal) {
        agents.observeScreen(*pane, *entry.screen.signal, entry.screen.time);
      }
    }
  }

  inline static void enqueueRetired(RuntimeModel<Memory> &model, typename Processor::Request &request) noexcept {
    auto *link = &model.retired_observers;
    while (*link && request.count < request.entries.size()) {
      auto &observer = **link;
      if (observer.idle()) {
        auto next = std::move(observer.retired_next);
        *link = std::move(next);
        --model.retired_observer_count;
        continue;
      }

      if (observer.seal()) {
        request.entries[request.count++].observer = *link;
      }

      link = &observer.retired_next;
    }
  }

  // A sole pane discovers its foreground group on the worker; others read it here.
  inline void enqueue(typename Processor::Request &request, const Agents &agents, Pane<Memory> &pane, bool sole) {
    if (auto drop = pane.observer->takeDrop()) {
      limits_.report(*drop);
    }

    const bool probe_process = !pane.exit_status;
    if (!pane.observer->seal(!pane.exit_status && pane.process_recheck_requested)) {
      return;
    }

    request.entries[request.count++] = {.pane = pane.id, .generation = pane.generation, .provider = AgentProvider::unknown, .observer = pane.observer, .probe_process = probe_process};
    auto &entry = request.entries[request.count - 1];
    entry.input_revision = pane.input_revision;
    entry.process_request = {pane.id, pane.generation, pane.cwd_revision, pane.process->processId(), 0};
    entry.process_request.cache = pane.process_cache;
    if (const auto *agent = agents.find(pane.id, pane.generation)) {
      entry.provider = agent->provider;
      entry.tracked_agent = true;
    }

    if (probe_process) {
      entry.process_request.discover_foreground = sole;
      if (!entry.process_request.discover_foreground) {
        entry.process_request.foreground = pane.process->foregroundProcessGroup().value_or(0);
      }

      entry.process_request.recheck = pane.process_recheck_requested;
      pane.process_recheck_running = pane.process_recheck_requested;
      pane.process_recheck_requested = false;
    }
  }

  inline static void applyProcess(Agents &agents, Pane<Memory> &pane, const ProcessProbeResult &observation) {
    if (pane.generation != observation.request.generation || pane.exit_status || pane.process->processId() != observation.request.root || pane.process->foregroundProcessGroup().value_or(0) != observation.request.foreground) {
      return;
    }

    pane.process_cache = observation.cache;
    if (!observation.name.view().empty() && pane.foreground.view() != observation.name.view()) {
      pane.foreground = observation.name;
      ++pane.foreground_revision;
    }

    agents.observeProcess(pane, observation);
  }

  Limits &limits_;
  ObservationWorker<Processor> worker_;
  std::size_t next_slot_ = 0;
  bool pending_ = false;
};

}
}

// Interface: runtime/runtime_clipboard_service.cppm
export {
namespace telar::runtime {

class RuntimeClipboardReader {
public:
  using Request = bool;
  using Result = std::expected<clipboard::content, clipboard::read_error>;

  inline Result observe(const Request &) noexcept {
    return clipboard::read(runtime_clipboard_max_bytes);
  }

  inline void stop() noexcept {}
};

// One bounded capture at a time. Pulling one chunk per request keeps a slow
// consumer from filling the response queue or stalling terminal delivery.
template <Allocator Memory, typename Reader = RuntimeClipboardReader>
class RuntimeClipboardService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto transfer_timeout = std::chrono::seconds{30};

  // The reader is built in place on its worker from the arguments.
  template <typename... Arguments>
  inline explicit RuntimeClipboardService(Arguments &&...reader)
      : worker_(std::in_place, std::forward<Arguments>(reader)...) {}

  // A transfer whose owner left, closed or timed out ends before the request is weighed.
  inline void read(ClientStore<Memory> &clients, std::uint64_t client_id, const ReadRuntimeClipboard &request) {
    expire(clients, Clock::now());
    auto &client = requireClient(clients, client_id);
    if (request.transfer_id != 0) {
      if (pending_ || owner_ != client.id || generation_ != client.generation ||
          transfer_ != request.transfer_id || offset_ != request.offset) {
        throw RequestError{FailureCode::invalid_request, "Clipboard transfer is absent, expired or out of sequence"};
      }
      send(client, request.request_id);
      return;
    }

    if (pending_ || owner_ != 0 || !worker_.submit(true)) {
      throw RequestError{FailureCode::resource_limit, "A clipboard capture or transfer is already pending"};
    }
    owner_ = client.id;
    generation_ = client.generation;
    transfer_ = request.request_id;
    offset_ = 0;
    pending_ = true;
    expires_ = Clock::now() + transfer_timeout;
  }

  inline void collect(ClientStore<Memory> &clients) {
    worker_.collect([&](typename Reader::Result &result) {
      pending_ = false;
      auto *client = clients.find(owner_);
      if (client == nullptr || client->generation != generation_ || client->connection.closing || Clock::now() >= expires_) {
        clear();
        return;
      }
      try {
        if (!result) {
          const auto code = result.error() == clipboard::read_error::content_too_large ? FailureCode::resource_limit : FailureCode::invalid_request;
          client->connection.send(RequestFailed{.request_id = transfer_, .code = code, .message = errorMessage(result.error())});
          clear();
          return;
        }
        content_ = std::move(*result);
        send(*client, transfer_);
      } catch (...) {
        clear();
        client->connection.closeImmediately();
      }
    });
  }

  inline void expire(const ClientStore<Memory> &clients, Clock::time_point now) noexcept {
    if (!pending_ && owner_ != 0) {
      const auto *client = clients.find(owner_);
      if (now >= expires_ || client == nullptr || client->generation != generation_ || client->connection.closing) {
        clear();
      }
    }
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  inline static std::string_view errorMessage(clipboard::read_error error) noexcept {
    if (error == clipboard::read_error::content_too_large) {
      return "Clipboard exceeds clipboard.max_capture_bytes (33554432 bytes)";
    }
    return clipboard::error_message(error);
  }

  inline void send(ClientSession<Memory> &client, std::uint64_t request) {
    const auto bytes = std::span<const Byte>{content_.bytes}.subspan(offset_);
    const auto part = bytes.first(std::min(bytes.size(), runtime_clipboard_chunk_bytes));
    client.connection.send(RuntimeClipboardChunk{.request_id = request, .transfer_id = transfer_, .offset = offset_, .total_bytes = content_.bytes.size(), .mime = content_.mime_type, .bytes = part});
    offset_ += part.size();
    if (offset_ == content_.bytes.size()) {
      clear();
    }
  }

  inline void clear() noexcept {
    // Captured bytes never enter history or checkpoints. Drop storage rather
    // than retaining a maximum-sized buffer between captures.
    content_ = {};
    owner_ = 0;
    generation_ = 0;
    transfer_ = 0;
    offset_ = 0;
  }

  ObservationWorker<Reader> worker_;
  clipboard::content content_;
  std::uint64_t owner_ = 0;
  std::uint64_t generation_ = 0;
  std::uint64_t transfer_ = 0;
  std::size_t offset_ = 0;
  Clock::time_point expires_{};
  bool pending_ = false;
};

}
}

// Interface: runtime/worktree_detection_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, WorktreeDetector Probe>
class WorktreeDetectionService {
public:
  // The probe is built in place on its worker from the arguments.
  template <typename... Arguments>
  inline explicit WorktreeDetectionService(Arguments &&...probe)
      : worker_(std::in_place, std::forward<Arguments>(probe)...) {}

  inline void tick(RuntimeModel<Memory> &model) {
    collect(model);
    if (pending_) {
      return;
    }

    for (auto *pane : model.panes.items()) {
      if (pane == nullptr || pane->worktree_checked_cwd == pane->cwd_revision) {
        continue;
      }
      pane->worktree_checked_cwd = pane->cwd_revision;
      if (pane->exit_status || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace || !pane->cwd.starts_with('/') || model.worktrees.containing(pane->cwd) != nullptr) {
        continue;
      }

      WorktreeDetectionRequest request{.pane = pane->id, .generation = pane->generation, .cwd_revision = pane->cwd_revision};
      request.cwd.assign(pane->cwd);
      if (worker_.submit(request)) {
        pending_ = true;
      } else {
        pane->worktree_checked_cwd.reset();
      }
      return;
    }
  }

  inline void collect(RuntimeModel<Memory> &model) {
    worker_.collect([&](const WorktreeDetectionResult &result) {
      pending_ = false;
      auto *pane = model.panes.find(result.pane);
      if (pane == nullptr || pane->generation != result.generation || pane->cwd_revision != result.cwd_revision || result.root_length == 0 || result.root_length > pane->cwd.size() || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace) {
        return;
      }

      try {
        const auto registered = model.worktrees.registerEntry(RegisterWorktree{
            .source = model.worktrees.sourceFor(pane->location.workspace.id),
            .origin = WorktreeOrigin::external,
            .path = std::string_view{pane->cwd}.substr(0, result.root_length),
            .branch = result.branch.view(),
        });
        model.workspace_revision += registered.created;
      } catch (const RequestError &) {
      }
    });
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  ObservationWorker<Probe> worker_;
  bool pending_ = false;
};

}
}
