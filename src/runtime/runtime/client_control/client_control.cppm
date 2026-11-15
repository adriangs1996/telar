module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.runtime.client_control;

import std;
import telar.tbc;

export import telar.runtime.agents.snapshot;
export import telar.runtime.platform.request_worker;

export import telar.runtime.model.client_layouts;

export import telar.runtime.platform.process_probe;

export import telar.runtime.metrics.host_sampler;

export import telar.runtime.observation.processor;

export import telar.runtime.worktrees.git_probe;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.client;
import telar.clipboard;

// Interface: runtime/agent_file_service.cppm
export {
  namespace telar::runtime {

    template <typename Agents>
    concept SessionFileObserver = requires(Agents& agents, const SessionFileResult& result, std::chrono::steady_clock::time_point now) {
      { agents.nextSessionFile(now) } -> std::same_as<std::optional<SessionFileRequest>>;
      { agents.completeSessionFile(result, now) } -> std::same_as<void>;
    };

    // Reads agents' session files on a worker; the agents are lent to each call.
    // Kept whole: Agents is the runtime's AgentService, from a module that imports this one.
    template <ConcurrentAllocator Memory, SessionFileObserver Agents>
    class TBC_GENERIC AgentFileService {
    public:
      inline explicit AgentFileService(Memory& memory)
          : worker_(std::in_place, memory) {}

      // Not inlined: publish() calls it on every wake, and its locals in publish()'s frame would span stack
      // pages that each cost a page fault after a pane's fork() (see Connection::read).
      [[gnu::noinline]] inline void tick(Agents& agents, std::chrono::steady_clock::time_point now) {
        collect(agents);
        if (!pending_) {
          if (const auto request = agents.nextSessionFile(now)) {
            pending_ = worker_.submit(*request);
          }
        }
      }

      inline void collect(Agents& agents) {
        if (!pending_) {
          return;
        }

        worker_.collect([&](const SessionFileResult& result) {
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
    class ClientControl {
    public:
      static void list(ClientStore& clients, std::uint64_t requester_id, const QueryClients& request);

      static void detach(ClientStore& clients, std::uint64_t requester_id, const DetachClient& request);

      static void requestCommand(ClientStore& clients, std::uint64_t requester_id, const RequestClientCommand& request);

      static void completeCommand(ClientStore& clients, std::uint64_t sender_id, const CompleteClientCommand& completion);

      static void requestFocus(const PaneStore& panes, ClientStore& clients, std::uint64_t requester_id, const RequestPaneFocus& request);

      static void completeFocus(ClientStore& clients, std::uint64_t sender_id, const CompletePaneFocus& completion);

      // Shows a notification on the interactive clients and tells the requester how many received it. The
      // confirmation takes its place in the requester's queue first, so a full queue refuses the request
      // before anything is shown; its count is filled in by offset once the clients are reached.
      static void notify(ClientStore& clients, std::uint64_t requester_id, const ShowNotification& request);

      static std::uint8_t publish(ClientStore& clients, const NotificationBody& body);

      static void abandon(ClientStore& clients, std::uint64_t departed) noexcept;

    private:
      static void requireRole(const ClientSession& client, ClientRole expected);

      static bool routable(const ClientSession* client) noexcept;

      static ClientSession* resolve(ClientStore& clients, ClientRoute target) noexcept;

      static ClientRoute route(const ClientSession& client) noexcept;

      static ClientSession* focusOrigin(ClientStore& clients, std::uint64_t pane_id) noexcept;

      static void failAbandoned(ClientSession& client, std::uint64_t request_id) noexcept;
    };

  }
}

// Interface: runtime/deferred_reports.cppm
export {
  namespace telar::runtime {

    enum class ReportDecision {
      accepted,
      deferred,
      rejected,
    };

    // Kept here: the message is any of the protocol's, an open set no unit can instantiate ahead.
    template <typename Message>
    TBC_GENERIC std::optional<ReporterIdentity> reporterOf(const AgentManifests& manifests, const Message& message) noexcept {
      if constexpr (std::same_as<Message, ReportAgent> || std::same_as<Message, ReportAgentTitle> || std::same_as<Message, ReportAgentProgress>) {
        return ReporterIdentity{message.pane_id, message.pane_generation, message.provider};
      } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
        return ReporterIdentity{message.pane_id, message.pane_generation, manifests.named(message.provider)};
      } else {
        return std::nullopt;
      }
    }

    template <typename Agents>
    concept ReporterAgents = requires(const Agents& agents, std::uint64_t pane, std::uint64_t generation) {
      { agents.find(pane, generation) } -> std::convertible_to<const Agent*>;
    };

    // Holds a report back until the pane's process is checked again. A held report keeps its payload in
    // its client; the runtime takes it out to replay it.
    // Kept whole: tests instantiate it with their own fake Agents (deferred_reports_test's RecordedAgents).
    template <ReporterAgents Agents>
    class TBC_GENERIC DeferredReports {
    public:
      // The clients whose held reports are due, in the order they were held.
      struct Due {
        std::array<std::uint64_t, client_capacity> clients{};
        std::size_t count = 0;

        inline std::span<const std::uint64_t> ids() const noexcept {
          return std::span{clients}.first(count);
        }
      };

      inline ReportDecision evaluate(PaneStore& panes, const Agents& agents, ClientSession& client, ReporterIdentity reporter, std::span<const Byte> payload) {
        if (reporter.provider == AgentProvider::unknown) {
          return ReportDecision::accepted;
        }

        auto* pane = &requireReporterPane(panes, client, reporter.pane, reporter.generation);

        if (accepts(agents, reporter)) {
          return ReportDecision::accepted;
        }

        auto& report = client.deferred_report;
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

      inline void cancel(ClientSession& client) noexcept {
        if (client.deferred_report.pending) {
          client.deferred_report.pending = false;
          client.connection.read_paused = false;
          --pending_;
        }
      }

      // Marks whether each due report's process was checked again.
      inline Due due(ClientStore& clients, const PaneStore& panes, const Agents& agents, ObservationTime now) const {
        Due due;

        if (pending_ == 0) {
          return due;
        }

        std::array<const ClientSession*, client_capacity> ready;

        for (auto* client : clients.items()) {
          if (client == nullptr || !client->deferred_report.pending) {
            continue;
          }

          auto& report = client->deferred_report;
          const auto* pane = findPane(panes, report.reporter.pane, report.reporter.generation);
          const bool gone = pane == nullptr || pane->exit_status;
          const bool timed_out = now.nanoseconds - report.observed.nanoseconds >= report_timeout.count();
          const bool rechecked = !gone && report.rechecked(pane->process_rechecks);
          const bool accepted = !gone && accepts(agents, report.reporter);
          if (gone || timed_out || rechecked || accepted) {
            report.answer_rechecked = rechecked || accepted;
            ready[due.count++] = client;
          }
        }

        auto ordered = std::span{ready}.first(due.count);

        std::ranges::sort(ordered, [](const auto* left, const auto* right) {
          return std::bit_cast<std::int64_t>(left->deferred_report.sequence - right->deferred_report.sequence) < 0;
        });

        for (std::size_t index = 0; index < due.count; ++index) {
          due.clients[index] = ordered[index]->id;
        }

        return due;
      }

      // Releases a due report to be answered and exchanges its payload with the caller's empty one, which
      // must share the client's allocator, as Rust's `mem::swap`.
      inline void open(ClientSession& client, Vector<Byte, ConcurrentMemory>& payload) noexcept {
        cancel(client);
        client.deferred_report.answering = true;
        client.connection.read_paused = false;
        payload.swap(client.deferred_report.payload);
      }

      // Ends the answer and gives the payload's storage back to the client.
      inline static void close(ClientSession& client, Vector<Byte, ConcurrentMemory>& payload) noexcept {
        payload.clear();
        payload.swap(client.deferred_report.payload);
        client.deferred_report.answering = false;
      }

    private:
      inline static bool accepts(const Agents& agents, ReporterIdentity reporter) noexcept {
        const auto* agent = agents.find(reporter.pane, reporter.generation);

        return agent == nullptr || agent->evidence.accepts(reporter.provider);
      }

      inline static std::optional<RejectedReporter> reportingRejection(const Agents& agents, const ClientSession& client, const Pane& pane) noexcept {
        const auto* agent = agents.find(pane.id, pane.generation);
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
    // Kept whole: tests instantiate it with their own fake Inspector (agents_test's TestProcessInspector).
    template <LineageInspector Inspector>
    class TBC_GENERIC DescentService {
    public:
      inline explicit DescentService(const Inspector& inspector)
          : worker_(std::in_place, inspector) {}

      inline static void verify(const PaneStore& panes, ClientSession& client, const VerifyPaneDescent& request) {
        const auto* pane = findPane(panes, request.pane_id, request.pane_generation);
        if (pane == nullptr || pane->exit_status) {
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

      inline void collect(ClientStore& clients, const PaneStore& panes) {
        if (!pending_) {
          return;
        }

        worker_.collect([&](const typename DescentProbe<Inspector>::Result& result) {
          pending_ = false;
          for (const auto& completed : std::span{result.checks}.first(result.count)) {
            finish(clients, panes, completed);
          }
        });

        schedule(clients);
      }

      inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

      // Submits the held checks no worker runs yet.
      inline void schedule(ClientStore& clients) {
        if (pending_) {
          return;
        }

        typename DescentProbe<Inspector>::Request request;

        for (auto* client : clients.items()) {
          if (client != nullptr && client->pending_descent && !client->descent_running && !client->connection.closing) {
            request.checks[request.count++] = *client->pending_descent;
          }
        }

        if (request.count == 0 || !worker_.submit(request)) {
          return;
        }

        pending_ = true;
        for (const auto& check : std::span{request.checks}.first(request.count)) {
          clients.find(check.client)->descent_running = true;
        }
      }

    private:
      inline static void finish(ClientStore& clients, const PaneStore& panes, const typename DescentProbe<Inspector>::Completion& completed) noexcept {
        const auto& check = completed.check;
        auto* client = clients.find(check.client);
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
          const auto* pane = findPane(panes, check.pane, check.pane_generation);
          if (pane == nullptr || pane->exit_status) {
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
    // Kept whole: tests instantiate it with their own fake Probe (metrics_test's FakeHostMetrics).
    template <typename Probe>
      requires HostMetricsProbe<std::remove_reference_t<Probe>>
    class TBC_GENERIC HostMetricsReader {
    public:
      using Request = HostSampler;
      using Result = HostSampler;

      template <typename... Arguments>
      inline explicit HostMetricsReader(Arguments&&... probe) noexcept
          : probe_(std::forward<Arguments>(probe)...) {}

      inline Result observe(const Request& previous) noexcept {
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

    // Kept whole: tests instantiate it with their own fake Probe (metrics_test's FakeHostMetrics).
    template <typename Probe>
      requires HostMetricsProbe<std::remove_reference_t<Probe>>
    class TBC_GENERIC HostMetricsService {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr auto sample_interval = std::chrono::seconds{2};

      template <typename... Arguments>
      inline explicit HostMetricsService(Clock::time_point started, Arguments&&... probe)
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
        worker_.collect([this](const HostSampler& sample) {
          sampler_ = sample;
        });
      }

      inline void publish(ClientSession& client) const {
        if (!client.subscribed || client.metrics_revision == sampler_.revision()) {
          return;
        }

        if (const auto& values = sampler_.latest()) {
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
      inline const diagnostics::SystemCounters& diagnostics() const noexcept {
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

    template <typename Agents>
    concept AgentObservationSink = requires(Agents& agents, Pane& pane, AgentSignal signal, ObservationTime time) {
      { agents.find(pane.id, pane.generation) } -> std::convertible_to<const Agent*>;
      { agents.observeScreen(pane, signal, time) } -> std::same_as<void>;
      { agents.observeProcess(pane, ProcessProbeResult{}) } -> std::same_as<void>;
    };

    template <typename Limits>
    concept ObservationLimitSink = requires(Limits& limits, const LimitReach& reach) {
      { limits.report(reach) } -> std::same_as<void>;
    };

    // Observes pane screens and processes on a worker. The model and the agents are lent to each call.
    // Kept whole: tests instantiate it with their own fakes (observation_test's UnusedAgents and DirectoryOnlyProbe).
    template <typename Agents, ObservationLimitSink Limits, PaneProcessProbe Probe, HistoryEventSink History>
      requires AgentObservationSink<Agents>
    class TBC_GENERIC PaneObservationService {
      using Processor = ObservationProcessor<Probe, History>;

    public:
      inline explicit PaneObservationService(Limits& limits, const AgentManifests& manifests, Probe& probe, History& history)
          : limits_(limits),
            worker_(std::in_place, manifests, probe, history) {}

      // Not inlined: publish() calls it on every wake, and its locals in publish()'s frame would span stack
      // pages that each cost a page fault after a pane's fork() (see Connection::read).
      [[gnu::noinline]] inline void refresh(RuntimeModel& model, Agents& agents) {
        collect(model, agents);
        if (pending_) {
          return;
        }

        typename Processor::Request request;

        enqueueRetired(model, request);
        const auto panes = model.panes.items();
        const bool sole = model.panes.size() == 1;
        const auto now = std::chrono::steady_clock::now();

        for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
          const auto slot = next_slot_++ % panes.size();
          auto* pane = panes[slot];
          if (pane == nullptr) {
            continue;
          }

          enqueue(request, agents, *pane, sole, now);
          if (request.count == request.entries.size()) {
            break;
          }
        }

        if (request.count != 0) {
          pending_ = worker_.submit(request);
        }
      }

      inline void observe(RuntimeModel& model, Agents& agents, std::uint64_t pane_id) {
        collect(model, agents);
        auto* pane = model.panes.find(pane_id);
        if (pending_ || pane == nullptr) {
          return;
        }

        typename Processor::Request request;

        enqueue(request, agents, *pane, model.panes.size() == 1, std::chrono::steady_clock::now());
        if (request.count != 0) {
          pending_ = worker_.submit(request);
        }
      }

      inline void collect(RuntimeModel& model, Agents& agents) {
        if (!pending_) {
          return;
        }

        worker_.collect([&](const typename Processor::Result& result) {
          apply(model, agents, result);
        });
      }

      inline void finish(RuntimeModel& model) noexcept {
        for (;;) {
          worker_.wait([&](const typename Processor::Result& result) {
            pending_ = false;
            for (const auto& entry : std::span{result.entries}.first(result.count)) {
              entry.observer->complete();
            }
          });

          typename Processor::Request request;

          for (auto* pane : model.panes.items()) {
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
      inline void apply(RuntimeModel& model, Agents& agents, const typename Processor::Result& result) {
        pending_ = false;
        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          entry.observer->complete();
        }

        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          TELAR_DIAGNOSTIC(model.metrics.observation.merge(entry.screen.metrics));
          if (entry.screen.failed) {
            limits_.report(LimitReach{.name = "history.observation_failures", .noun = "failed observations", .route = "history"});
          }

          auto* pane = findPane(model.panes, entry.pane, entry.generation);
          if (pane == nullptr || pane->exit_status) {
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

          // Whether the observation still describes the pane's process, asked once: it reads the
          // terminal's foreground group with a system call.
          const bool current = entry.process_result && (entry.process_result->inspected || entry.process_result->ports_inspected) && observes(*pane, *entry.process_result);

          if (entry.process_result && entry.process_result->inspected) {
            TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_inspections));
            TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_misses, entry.process_result->provider == AgentProvider::unknown));
            model.pane_revision += current && applyProcess(agents, *pane, *entry.process_result);
          }

          if (entry.process_result && entry.process_result->ports_inspected) {
            model.pane_revision += current && applyPorts(*pane, *entry.process_result);
          }

          if (entry.screen.signal) {
            agents.observeScreen(*pane, *entry.screen.signal, entry.screen.time);
          }
        }
      }

      // The request shares the observers of region `a`.
      inline static void enqueueRetired(tbc::view<RuntimeModel&, tbc::lt::a> model, tbc::view<typename Processor::Request&, tbc::lt::a> request) noexcept {
        auto* link = &model.retired_observers;

        while (*link && request.count < request.entries.size()) {
          auto& observer = **link;
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

      // A sole pane discovers its foreground group on the worker; others read it here. A program's
      // listening ports are read again every `ports_interval`, output or not.
      inline void enqueue(tbc::view<typename Processor::Request&, tbc::lt::a> request, const Agents& agents, tbc::view<Pane&, tbc::lt::a> pane, bool sole, std::chrono::steady_clock::time_point now) {
        if (auto drop = pane.observer->takeDrop()) {
          limits_.report(*drop);
        }

        const bool probe_process = !pane.exit_status;
        // An agent's card shows no ports, so its pane is not read for them.
        const auto* agent = agents.find(pane.id, pane.generation);
        const bool ports_due = probe_process && agent == nullptr && !pane.foreground_shell && now - pane.ports_checked >= ports_interval;
        if (!pane.observer->seal(probe_process && (pane.process_recheck_requested || ports_due))) {
          return;
        }

        request.entries[request.count++] = {.pane = pane.id, .generation = pane.generation, .provider = AgentProvider::unknown, .observer = pane.observer, .probe_process = probe_process};
        auto& entry = request.entries[request.count - 1];

        entry.input_revision = pane.input_revision;
        entry.process_request = {pane.id, pane.generation, pane.cwd_revision, pane.process->processId(), 0};
        entry.process_request.cache = pane.process_cache;
        if (agent != nullptr) {
          entry.provider = agent->provider;
          entry.tracked_agent = true;
        }

        if (probe_process) {
          entry.process_request.discover_foreground = sole;
          if (!entry.process_request.discover_foreground) {
            entry.process_request.foreground = pane.process->foregroundProcessGroup().value_or(0);
          }

          entry.process_request.recheck = pane.process_recheck_requested;
          entry.process_request.ports = ports_due;
          pane.process_recheck_running = pane.process_recheck_requested;
          pane.process_recheck_requested = false;
          if (ports_due) {
            pane.ports_checked = now;
          }
        }
      }

      inline static bool observes(const Pane& pane, const ProcessProbeResult& observation) {
        return pane.generation == observation.request.generation && !pane.exit_status && pane.process->processId() == observation.request.root && pane.process->foregroundProcessGroup().value_or(0) == observation.request.foreground;
      }

      // Whether the pane list changed, for an observation of the pane's current process.
      inline static bool applyPorts(Pane& pane, const ProcessProbeResult& observation) {
        if (pane.listening_ports == observation.ports) {
          return false;
        }

        pane.listening_ports = observation.ports;

        return true;
      }

      // Whether the pane list changed, for an observation of the pane's current process.
      inline static bool applyProcess(Agents& agents, Pane& pane, const ProcessProbeResult& observation) {
        pane.process_cache = observation.cache;
        bool listed = false;

        if (!observation.name.view().empty() && pane.foreground.view() != observation.name.view()) {
          pane.foreground = observation.name;
          ++pane.foreground_revision;
          listed = true;
        }

        // A command pane execs its program in place of the launching shell, so the root holding the
        // terminal is an idle shell only while it still runs one.
        const auto shell = observation.request.foreground == observation.request.root && !loginShellScript(pane.foreground.view()).empty();
        if (listed || pane.foreground_group != observation.request.foreground || pane.foreground_shell != shell) {
          // The ports belonged to the previous program; the next observation reads the new one's.
          pane.foreground_since = std::chrono::steady_clock::now();
          pane.foreground_group = observation.request.foreground;
          pane.foreground_shell = shell;
          pane.listening_ports = {};
          pane.ports_checked = {};
          listed = true;
        }

        agents.observeProcess(pane, observation);

        return listed;
      }

      static constexpr std::chrono::seconds ports_interval{2};

      Limits& limits_;
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

      Result observe(const Request&) noexcept;

      void stop() noexcept;
    };

    // One bounded capture at a time. Pulling one chunk per request keeps a slow
    // consumer from filling the response queue or stalling terminal delivery.
    // Kept whole: tests instantiate it with their own fake Reader (runtime_clipboard_test's Reader).
    template <typename Reader = RuntimeClipboardReader>
    class TBC_GENERIC RuntimeClipboardService {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr auto transfer_timeout = std::chrono::seconds{30};

      // The reader is built in place on its worker from the arguments.
      template <typename... Arguments>
      inline explicit RuntimeClipboardService(Arguments&&... reader)
          : worker_(std::in_place, std::forward<Arguments>(reader)...) {}

      // A transfer whose owner left, closed or timed out ends before the request is weighed.
      inline void read(ClientStore& clients, std::uint64_t client_id, const ReadRuntimeClipboard& request) {
        expire(clients, Clock::now());
        auto& client = requireClient(clients, client_id);

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

      inline void collect(ClientStore& clients) {
        worker_.collect([&](typename Reader::Result& result) {
          pending_ = false;
          auto* client = clients.find(owner_);
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

      inline void expire(const ClientStore& clients, Clock::time_point now) noexcept {
        if (!pending_ && owner_ != 0) {
          const auto* client = clients.find(owner_);
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

      inline void send(ClientSession& client, std::uint64_t request) {
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

    // Kept whole: tests instantiate it with their own fake Probe (worktree_detection_test's GatedWorktreeDetector).
    template <WorktreeDetector Probe>
    class TBC_GENERIC WorktreeDetectionService {
    public:
      // The probe is built in place on its worker from the arguments.
      template <typename... Arguments>
      inline explicit WorktreeDetectionService(Arguments&&... probe)
          : worker_(std::in_place, std::forward<Arguments>(probe)...) {}

      // Not inlined: publish() calls it on every wake, and its locals in publish()'s frame would span stack
      // pages that each cost a page fault after a pane's fork() (see Connection::read).
      [[gnu::noinline]] inline void tick(RuntimeModel& model) {
        collect(model);
        if (pending_) {
          return;
        }

        for (auto* pane : model.panes.items()) {
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

      inline void collect(RuntimeModel& model) {
        worker_.collect([&](const WorktreeDetectionResult& result) {
          pending_ = false;
          auto* pane = findPane(model.panes, result.pane, result.generation);
          if (pane == nullptr || pane->cwd_revision != result.cwd_revision || result.root_length == 0 || result.root_length > pane->cwd.size() || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace) {
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
          } catch (const RequestError&) {
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
