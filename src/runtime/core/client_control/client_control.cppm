module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.core.client_control;

import std;
import telar.tbc;

import telar.runtime.agents.snapshot;
import telar.runtime.workers.request_worker;

import telar.runtime.core.model.client_layouts;

import telar.runtime.host.process_probe;

import telar.runtime.metrics.host_sampler;
import telar.runtime.metrics.monitor;
import telar.runtime.host.process_table;
import telar.sys.process;
import telar.wire.monitor;

import telar.runtime.agents.observation.processor;

import telar.runtime.workspaces.worktrees.git_probe;
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
import telar.runtime.terminal.control;
import telar.client;
import telar.clipboard;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.platform.events;
import telar.runtime.agents.description_generator;
import telar.runtime.core.model.slot_store;
import telar.runtime.history.event;
import telar.runtime.host.host_metrics;
import telar.platform.process;
import telar.runtime.diagnostics.runtime_counters;
import telar.base.ds;

// Interface: runtime/agent_file_service.cppm
export {
  namespace telar::runtime {

    template <typename Agents>
    concept SessionFileObserver = requires(Agents& agents, const SessionFileResult& result, std::chrono::steady_clock::time_point now) {
      { agents.nextSessionFile(now) } -> std::same_as<ds::Option<SessionFileRequest>>;
      { agents.completeSessionFile(result, now) } -> std::same_as<void>;
    };

    // Reads agents' session files on a worker; the agents are lent to each call.
    // Kept whole: Agents is the runtime's AgentService, from a module that imports this one.
    template <ConcurrentAllocator Memory, SessionFileObserver Agents>
    class [[tbc::generic]] AgentFileService {
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

      [[nodiscard]] inline int descriptor() const noexcept {
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

    enum class ReportDecision : std::uint8_t {
      accepted,
      deferred,
      rejected,
    };

    // Kept here: the message is any of the protocol's, an open set no unit can instantiate ahead.
    template <typename Message>
    [[tbc::generic]] ds::Option<ReporterIdentity> reporterOf(const AgentManifests& manifests, const Message& message) noexcept {
      if constexpr (std::same_as<Message, ReportAgent> || std::same_as<Message, ReportAgentTitle> || std::same_as<Message, ReportAgentProgress>) {
        return ReporterIdentity{message.pane_id, message.pane_generation, message.provider};
      } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
        return ReporterIdentity{message.pane_id, message.pane_generation, manifests.named(message.provider)};
      } else {
        return ds::none;
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
    class [[tbc::generic]] DeferredReports {
    public:
      // The clients whose held reports are due, in the order they were held.
      struct Due {
        ds::Array<std::uint64_t, client_capacity> clients{};
        std::size_t count = 0;

        [[nodiscard]] inline std::span<const std::uint64_t> ids() const noexcept {
          return std::span{clients}.first(count);
        }
      };

      inline ReportDecision evaluate(PaneStore& panes, const Agents& agents, ClientSession& client, ReporterIdentity reporter, std::span<const Byte> payload) {
        if (reporter.provider == AgentProvider::unknown) {
          return ReportDecision::accepted;
        }

        auto* pane = &requireReporterPane(panes, client, {.id = reporter.pane, .generation = reporter.generation});

        if (accepts(agents, reporter)) {
          return ReportDecision::accepted;
        }

        const auto rejection = reportingRejection(agents, client, *pane);
        auto& report = client.deferred_report;

        if (report.answering) {
          if (report.answer_rechecked && rejection) {
            pane->rejected_reporter = rejection;
          }

          return ReportDecision::rejected;
        }

        if (rejection && pane->rejected_reporter == rejection) {
          return ReportDecision::rejected;
        }

        report.payload.clear();
        report.payload.extend({payload.begin(), payload.end()});
        report.reporter = reporter;
        report.required_recheck = pane->process_rechecks + (pane->process_recheck_running ? 2 : 1);
        report.observed = ObservationTime::now();
        report.sequence = ++sequence_;
        report.pending = true;
        client.connection.flagsMut().read_paused = true;
        pane->process_recheck_requested = true;
        ++pending_;
        return ReportDecision::deferred;
      }

      inline void cancel(ClientSession& client) noexcept {
        if (client.deferred_report.pending) {
          client.deferred_report.pending = false;
          client.connection.flagsMut().read_paused = false;
          --pending_;
        }
      }

      // Marks whether each due report's process was checked again.
      inline Due due(ClientStore& clients, const PaneStore& panes, const Agents& agents, ObservationTime now) const {
        Due due;

        if (pending_ == 0) {
          return due;
        }

        ds::Array<const ClientSession*, client_capacity> ready{};

        for (auto* client : clients.items()) {
          if (client == nullptr || !client->deferred_report.pending) {
            continue;
          }

          auto& report = client->deferred_report;
          const auto* pane = findPane(panes, {.id = report.reporter.pane, .generation = report.reporter.generation});
          const bool gone = pane == nullptr || pane->exit_status;
          const bool timed_out = now.nanoseconds - report.observed.nanoseconds >= report_timeout.count();
          const bool rechecked = !gone && report.rechecked(pane->process_rechecks);
          const bool accepted = !gone && accepts(agents, report.reporter);
          if (gone || timed_out || rechecked || accepted) {
            report.answer_rechecked = rechecked || accepted;
            ready.atMut(due.count++) = client;
          }
        }

        auto ordered = ready.viewMut().first(due.count);

        std::ranges::sort(ordered, [](const auto* left, const auto* right) {
          return std::bit_cast<std::int64_t>(left->deferred_report.sequence - right->deferred_report.sequence) < 0;
        });

        for (std::size_t index = 0; index < due.count; ++index) {
          due.clients.atMut(index) = ordered[index]->id;
        }

        return due;
      }

      // Releases a due report to be answered and exchanges its payload with the caller's empty one, which
      // must share the client's allocator, as Rust's `mem::swap`.
      inline void open(ClientSession& client, ds::Vec<Byte, ConcurrentMemory>& payload) noexcept { // NOLINT(bugprone-exception-escape): the payloads share the client's allocator, so the swap hands storage over without allocating
        cancel(client);
        client.deferred_report.answering = true;
        client.connection.flagsMut().read_paused = false;
        std::swap(payload, client.deferred_report.payload);
      }

      // Ends the answer and gives the payload's storage back to the client.
      inline static void close(ClientSession& client, ds::Vec<Byte, ConcurrentMemory>& payload) noexcept { // NOLINT(bugprone-exception-escape): the payloads share the client's allocator, so the swap hands storage over without allocating
        payload.clear();
        std::swap(payload, client.deferred_report.payload);
        client.deferred_report.answering = false;
      }

    private:
      inline static bool accepts(const Agents& agents, ReporterIdentity reporter) noexcept {
        const auto* agent = agents.find(reporter.pane, reporter.generation);

        return agent == nullptr || agent->evidence.accepts(reporter.provider);
      }

      inline static ds::Option<RejectedReporter> reportingRejection(const Agents& agents, const ClientSession& client, const Pane& pane) noexcept {
        const auto* agent = agents.find(pane.id, pane.generation);
        if (agent == nullptr || !agent->agent_identity || !agent->process_identity) {
          return ds::none;
        }

        const auto group = agent->process_identity->pid;
        const auto member = agent->agent_identity->pid;
        const auto root = pane.process_id;
        const auto lineage = client.verified_lineage.ancestors();

        for (std::size_t index = 0; index < lineage.size(); ++index) {
          if (lineage[index] != member && lineage[index] != group && lineage[index] != root) {
            continue;
          }

          if (index == 0 || lineage[index - 1] == member || lineage[index - 1] == group) {
            return ds::none;
          }

          return RejectedReporter{group, member, lineage[index - 1]};
        }

        return ds::none;
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
    class [[tbc::generic]] DescentService {
    public:
      inline explicit DescentService(const Inspector& inspector)
          : worker_(std::in_place, inspector) {}

      inline static void verify(const PaneStore& panes, ClientSession& client, const VerifyPaneDescent& request) {
        const auto* pane = findPane(panes, {.id = request.pane_id, .generation = request.pane_generation});
        if (pane == nullptr || pane->exit_status) {
          throw RequestError{FailureCode::pane_not_found, "Pane not found"};
        }

        if (client.pending_descent) {
          throw RequestError{FailureCode::resource_limit, "A descent verification is already pending"};
        }

        client.verified_pane = 0;
        client.verified_generation = 0;
        client.verified_lineage = {};
        if (!client.peer_identity || pane->process_id <= 0) {
          throw RequestError{FailureCode::foreign_process, "The process does not descend from this pane"};
        }

        client.pending_descent = DescentCheck{.client = client.id, .client_generation = client.generation, .pane = pane->id, .pane_generation = pane->generation, .request_id = request.request_id, .peer = *client.peer_identity, .root = pane->process_id};
        client.connection.flagsMut().read_paused = true;
      }

      inline void collect(ClientStore& clients, const PaneStore& panes) {
        if (!pending_) {
          return;
        }

        worker_.collect([&](const DescentProbe<Inspector>::Result& result) {
          pending_ = false;
          for (const auto& completed : std::span{result.checks}.first(result.count)) {
            finish(clients, panes, completed);
          }
        });

        schedule(clients);
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

      // Submits the held checks no worker runs yet.
      inline void schedule(ClientStore& clients) {
        if (pending_) {
          return;
        }

        typename DescentProbe<Inspector>::Request request;

        for (const auto* client : clients.items()) {
          if (client != nullptr && client->pending_descent && !client->descent_running && !client->connection.flags().closing) {
            request.checks.atMut(request.count++) = *client->pending_descent;
          }
        }

        if (request.count == 0 || !worker_.submit(request)) {
          return;
        }

        pending_ = true;
        for (const auto& check : std::span{request.checks}.first(request.count)) {
          if (auto* client = clients.find(check.client)) {
            client->descent_running = true;
          }
        }
      }

    private:
      inline static void finish(ClientStore& clients, const PaneStore& panes, const DescentProbe<Inspector>::Completion& completed) noexcept {
        const auto& check = completed.check;
        auto* client = clients.find(check.client);
        if (client == nullptr || client->generation != check.client_generation) {
          return;
        }

        client->pending_descent.reset();
        client->descent_running = false;
        client->connection.flagsMut().read_paused = false;
        if (client->connection.flags().closing) {
          return;
        }

        try {
          const auto* pane = findPane(panes, {.id = check.pane, .generation = check.pane_generation});
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
          client->connection.flagsMut().closing = true;
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
    class [[tbc::generic]] HostMetricsReader {
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
    class [[tbc::generic]] HostMetricsService {
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
              .has_battery = values->battery_percent.hasValue(),
              .battery_percent = values->battery_percent.valueOr(0),
              .cpu_count = values->cpu_count,
              .memory_total_decigib = values->memory_total_decigib,
          });
        }

        client.metrics_revision = sampler_.revision();
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

#if TELAR_DIAGNOSTICS
      [[nodiscard]] inline const diagnostics::SystemCounters& diagnostics() const noexcept {
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

// Interface: runtime/monitor_service.cppm
export {
  namespace telar::runtime {

    template <typename Processes>
    concept ProcessTableProbe = requires(Processes& processes, ds::Vec<ProcessRecord, ConcurrentMemory>& records) {
      { processes.read(records) } -> std::same_as<bool>;
    };

    struct MonitorLimitsOfWork {
      static constexpr std::size_t maximum_roots = 256;
      static constexpr std::size_t maximum_queries = MonitorSampler::maximum_answers;
      static constexpr std::size_t maximum_actions = 16;
    };

    struct MonitorQueryTicket {
      std::uint64_t client = 0;
      std::uint64_t request_id = 0;
      MonitorView view{};
    };

    // A signal, or a nice value when `signal` is none, for one process instance.
    struct MonitorActionTicket {
      std::uint64_t client = 0;
      std::uint64_t request_id = 0;
      ProcessInstance process{};
      ds::Option<ProcessSignal> signal;
      std::int32_t nice = 0;
      // The process that asked, when the runtime could name it.
      ds::Option<ProcessIdentity> peer;
    };

    // What the runtime hands the monitor's worker: take a reading, answer queries, act on processes.
    struct MonitorWork {
      bool sample = false;
      ds::Array<PaneRoot, MonitorLimitsOfWork::maximum_roots> roots{};
      std::uint16_t root_count = 0;
      // The processes of the runtime's clients.
      ds::Array<pid_t, maximum_monitor_clients> clients{};
      std::uint8_t client_count = 0;
      ds::Array<MonitorQueryTicket, MonitorLimitsOfWork::maximum_queries> queries{};
      std::uint8_t query_count = 0;
      ds::Array<MonitorActionTicket, MonitorLimitsOfWork::maximum_actions> actions{};
      std::uint8_t action_count = 0;
    };

    struct MonitorAnswer {
      // Valid until the next work is submitted: it views the sampler.
      ds::Option<MonitorSnapshot> snapshot;
    };

    struct MonitorActionOutcome {
      ds::Option<FailureCode> failure;
      std::string_view message;
    };

    struct MonitorOutcome {
      bool sampled = false;
      // False when the sampler had too few readings to answer the queries, which wait for the next.
      bool answered = false;
      ds::Array<MonitorAnswer, MonitorLimitsOfWork::maximum_queries> answers{};
      ds::Array<MonitorActionOutcome, MonitorLimitsOfWork::maximum_actions> actions{};
    };

    // The monitor's worker: reads the processes and the host, keeps the sampler, and signals.
    // Kept whole: tests instantiate it with their own fake probes.
    template <typename Processes, typename Host>
      requires ProcessTableProbe<Processes> && HostDetailProbe<Host>
    class [[tbc::generic]] MonitorReader {
    public:
      using Request = MonitorWork;
      using Result = MonitorOutcome;

      inline MonitorReader(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<ProcessInspector> inspector, Processes processes, Host host)
          : inspector_(inspector),
            processes_(std::move(processes)),
            host_(std::move(host)),
            sampler_(memory, inspector, siblingPrograms()),
            records_(memory) {}

      inline Result observe(const Request& work) noexcept {
        MonitorOutcome outcome;

        for (std::size_t index = 0; index < work.action_count; ++index) {
          outcome.actions.atMut(index) = act(work, work.actions[index]);
        }

        try {
          if (work.sample && processes_.read(records_) && host_.read(detail_)) {
            sampler_.update(records_, detail_, {.now = std::chrono::steady_clock::now(), .started_clock = ProcessTable::clock()}, {work.roots.data(), work.root_count}, {work.clients.data(), work.client_count});
            outcome.sampled = true;
          }

          if (work.query_count != 0 && sampler_.ready()) {
            answerQueries(work, outcome);
          }
        } catch (...) {
          records_.clear();
        }

        return outcome;
      }

      inline void stop() noexcept {}

    private:
      // The answers view the sampler, region `a`, until the next work is submitted.
      inline void answerQueries(const Request& work, tbc::mut_a<MonitorOutcome> outcome) {
        ds::Array<MonitorView, MonitorLimitsOfWork::maximum_queries> views{};

        for (std::size_t index = 0; index < work.query_count; ++index) {
          views.atMut(index) = work.queries[index].view;
        }

        const auto answers = sampler_.answer({views.data(), work.query_count});

        for (std::size_t index = 0; index < work.query_count; ++index) {
          auto& answer = outcome.answers.atMut(index).snapshot;

          answer = answers[index];
          if (answer) {
            answer.getMut().request_id = work.queries[index].request_id;
          }
        }

        outcome.answered = true;
      }

      inline static int nativeSignal(ProcessSignal signal) noexcept {
        switch (signal) {
        case ProcessSignal::terminate:
          return SIGTERM;
        case ProcessSignal::kill:
          return SIGKILL;
        case ProcessSignal::stop:
          return SIGSTOP;
        case ProcessSignal::resume:
          return SIGCONT;
        case ProcessSignal::hang_up:
          return SIGHUP;
        case ProcessSignal::interrupt:
          return SIGINT;
        }

        return SIGTERM;
      }

      // An agent may act only on the processes of the pane it runs in; anything else asks the user.
      [[nodiscard]] inline MonitorActionOutcome act(const MonitorWork& work, const MonitorActionTicket& action) const noexcept {
        if (action.peer) {
          for (std::size_t index = 0; index < work.root_count; ++index) {
            const auto& root = work.roots[index];
            if (!root.agent || !inspector_.descendsFrom(*action.peer, root.process)) {
              continue;
            }

            const auto target = inspector_.identity(action.process.pid);
            if (!target || !inspector_.descendsFrom(*target, root.process)) {
              return {.failure = FailureCode::foreign_process, .message = "An agent may act only on the processes of its own pane"};
            }

            break;
          }
        }

        const auto result = action.signal ? ProcessTable::signal(action.process, nativeSignal(*action.signal)) : ProcessTable::prioritize(action.process, action.nice);

        switch (result) {
        case ProcessActionResult::done:
          return {};
        case ProcessActionResult::gone:
          return {.failure = FailureCode::process_not_found, .message = "The process is gone, or another process has its pid now"};
        case ProcessActionResult::denied:
          return {.failure = FailureCode::permission_denied, .message = "The runtime's user may not act on this process"};
        case ProcessActionResult::failed:
          break;
        }

        return {.failure = FailureCode::internal, .message = "The system refused the request"};
      }

      tbc::val_a<ProcessInspector> inspector_;
      Processes processes_;
      Host host_;
      tbc::val_a<MonitorSampler> sampler_;
      tbc::val_a<ds::Vec<ProcessRecord, ConcurrentMemory>> records_;
      HostDetail detail_{};
    };

    // Reads the processes only while someone asks: every 2 s for 10 s after the last query. A query
    // that finds the sampler cold waits for two readings 1 s apart, since a CPU share needs both.
    // Kept whole: tests instantiate it with their own fake probes.
    template <typename Processes, typename Host>
      requires ProcessTableProbe<Processes> && HostDetailProbe<Host>
    class [[tbc::generic]] MonitorService {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr auto sample_interval = std::chrono::seconds{2};
      static constexpr auto warm_interval = std::chrono::seconds{1};
      static constexpr auto idle_after = std::chrono::seconds{10};

      inline MonitorService(tbc::mut_a<ConcurrentMemory> memory, tbc::ref_a<ProcessInspector> inspector, Processes processes, Host host)
          : worker_(std::in_place, memory, inspector, std::move(processes), std::move(host)) {}

      inline void query(std::uint64_t client, const QueryMonitor& message, Clock::time_point now) {
        if (pending_queries_ == MonitorLimitsOfWork::maximum_queries) {
          throw RequestError{FailureCode::resource_limit, "Too many monitor queries are waiting"};
        }

        auto& ticket = queries_.atMut(pending_queries_++);

        ticket = {.client = client, .request_id = message.request_id};
        ticket.view = {
            .sections = message.sections,
            .sort = message.sort,
            .reverse = message.reverse,
            .scope = message.scope,
            .layout = message.layout,
            .offset = message.offset,
            .limit = message.limit,
            .fold = message.fold,
            .detail = message.detail,
        };

        ticket.view.filter.assign(message.filter);
        ticket.view.toggled_count = static_cast<std::uint8_t>(std::min(message.toggled.size(), ticket.view.toggled.size()));
        std::ranges::copy(message.toggled.first(ticket.view.toggled_count), ticket.view.toggled.dataMut());
        wake(now);
      }

      inline void act(const MonitorActionTicket& action) {
        if (pending_actions_ == MonitorLimitsOfWork::maximum_actions) {
          throw RequestError{FailureCode::resource_limit, "Too many process requests are waiting"};
        }

        actions_.atMut(pending_actions_++) = action;
      }

      // Submits the work that is due; `roots` fills the panes' shells into the work. Returns the time
      // until work is next due.
      template <typename Roots>
      inline std::chrono::nanoseconds tick(Clock::time_point now, Roots&& roots) {
        constexpr auto idle = std::chrono::hours{1};
        const auto active = now < active_until_;
        if (!active && readings_ != 0) {
          readings_ = 0;
        }

        if (busy_) {
          return active ? std::max<std::chrono::nanoseconds>(next_sample_ - now, std::chrono::milliseconds{1}) : idle;
        }

        const auto due = active && now >= next_sample_;
        // Queries go with a reading that makes the sampler ready, or alone once it is.
        const auto answerable = pending_queries_ != 0 && (readings_ >= 2 || (due && readings_ == 1));
        if (!due && !answerable && pending_actions_ == 0) {
          return active ? next_sample_ - now : idle;
        }

        work_.sample = due;
        work_.root_count = 0;
        work_.client_count = 0;
        std::forward<Roots>(roots)(work_);
        work_.query_count = answerable ? static_cast<std::uint8_t>(pending_queries_) : 0;
        for (std::size_t index = 0; index < work_.query_count; ++index) {
          work_.queries.atMut(index) = queries_[index];
        }

        work_.action_count = static_cast<std::uint8_t>(pending_actions_);
        for (std::size_t index = 0; index < pending_actions_; ++index) {
          work_.actions.atMut(index) = actions_[index];
        }

        if (!worker_.submit(work_)) {
          return std::chrono::milliseconds{1};
        }

        busy_ = true;
        pending_actions_ = 0;
        if (answerable) {
          pending_queries_ = 0;
        }

        if (due) {
          next_sample_ = now + (readings_ == 0 ? warm_interval : sample_interval);
        }

        return active ? next_sample_ - now : idle;
      }

      // Calls `reply(client, message)` with each answer and each failure, while the answers still
      // view the worker's sampler.
      template <typename Reply>
      inline void collect(const Reply& reply) {
        worker_.collect([&](MonitorOutcome& outcome) {
          busy_ = false;
          if (outcome.sampled && readings_ < 2) {
            ++readings_;
          }

          for (std::size_t index = 0; index < work_.action_count; ++index) {
            const auto& action = work_.actions[index];
            const auto& result = outcome.actions[index];

            if (result.failure) {
              reply(action.client, RequestFailed{.request_id = action.request_id, .code = *result.failure, .message = result.message});
            } else {
              reply(action.client, RequestCompleted{.request_id = action.request_id});
            }
          }

          if (!outcome.answered) {
            requeue();
            return;
          }

          for (std::size_t index = 0; index < work_.query_count; ++index) {
            const auto& query = work_.queries[index];
            const auto& answer = outcome.answers[index].snapshot;

            if (answer) {
              reply(query.client, *answer);
            } else {
              reply(query.client, RequestFailed{.request_id = query.request_id, .code = FailureCode::process_not_found, .message = "The process is gone, or another process has its pid now"});
            }
          }
        });
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

    private:
      inline void wake(Clock::time_point now) {
        if (now >= active_until_) {
          readings_ = 0;
          next_sample_ = now;
        }

        active_until_ = now + idle_after;
      }

      // Puts the queries the worker could not answer back in front of the ones that came since.
      inline void requeue() {
        const auto returned = std::min<std::size_t>(work_.query_count, MonitorLimitsOfWork::maximum_queries - pending_queries_);

        for (auto index = pending_queries_; index-- > 0;) {
          queries_.atMut(index + returned) = queries_[index];
        }

        for (std::size_t index = 0; index < returned; ++index) {
          queries_.atMut(index) = work_.queries[index];
        }

        pending_queries_ += returned;
      }

      ObservationWorker<MonitorReader<Processes, Host>> worker_;
      MonitorWork work_{};
      ds::Array<MonitorQueryTicket, MonitorLimitsOfWork::maximum_queries> queries_{};
      std::size_t pending_queries_ = 0;
      ds::Array<MonitorActionTicket, MonitorLimitsOfWork::maximum_actions> actions_{};
      std::size_t pending_actions_ = 0;
      Clock::time_point active_until_;
      Clock::time_point next_sample_;
      std::uint8_t readings_ = 0;
      bool busy_ = false;
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
    class [[tbc::generic]] PaneObservationService {
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
          // What a terminal prints is read for the agent in it; another kind of pane prints nothing.
          auto* const pane = panes[slot];
          if (!asTerminal(pane)) {
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
        auto* found = model.panes.find(pane_id);
        if (pending_ || found == nullptr || !asTerminal(found)) {
          return;
        }

        typename Processor::Request request;

        enqueue(request, agents, *found, model.panes.size() == 1, std::chrono::steady_clock::now());
        if (request.count != 0) {
          pending_ = worker_.submit(request);
        }
      }

      inline void collect(RuntimeModel& model, Agents& agents) {
        if (!pending_) {
          return;
        }

        worker_.collect([&](const Processor::Result& result) {
          apply(model, agents, result);
        });
      }

      inline void finish(RuntimeModel& model) noexcept {
        for (;;) {
          worker_.wait([&](const Processor::Result& result) {
            pending_ = false;
            for (const auto& entry : std::span{result.entries}.first(result.count)) {
              entry.observer->complete();
            }
          });

          typename Processor::Request request;

          for (auto* stored : model.panes.items()) {
            const auto pane = asTerminal(stored);
            if (!pane || !pane->body.observer->seal()) {
              continue;
            }

            request.entries.atMut(request.count++).observer = pane->body.observer;
            if (request.count == request.entries.size()) {
              break;
            }
          }

          enqueueRetired(model, request);
          if (request.count == 0) {
            return;
          }

          pending_ = worker_.submit(request);
        }
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

    private:
      inline void apply(RuntimeModel& model, Agents& agents, const Processor::Result& result) {
        pending_ = false;
        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          entry.observer->complete();
        }

        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          TELAR_DIAGNOSTIC(model.metrics.observation.merge(entry.screen.metrics));
          if (entry.screen.failed) {
            limits_.report(LimitReach{.name = "history.observation_failures", .noun = "failed observations", .route = "history"});
          }

          applyEntry(model, agents, entry);
        }
      }

      // Applies one pane's observation, unless the pane is gone or exited since it was taken.
      inline static void applyEntry(RuntimeModel& model, Agents& agents, const Processor::ResultEntry& entry) {
        auto* found = findPane(model.panes, {.id = entry.pane, .generation = entry.generation});
        auto pane = asTerminal(found);
        if (!pane || pane->core.exit_status) {
          return;
        }

        if (entry.process_recheck) {
          pane.getMut().core.process_recheck_running = false;
          ++pane.getMut().core.process_rechecks;
        }

        pane.getMut().body.shell_markers = entry.screen.shell_markers && !entry.screen.failed;
        if (pane->core.input_revision == entry.input_revision) {
          pane.getMut().body.needs_foreground_observation = entry.screen.needs_foreground;
        }

        const auto directory = entry.observer->observedDirectory();
        if (pane->core.cwd_revision == entry.cwd_revision && !directory.empty() && pane->core.cwd != directory) {
          pane.getMut().core.cwd.assign(directory);
          ++pane.getMut().core.cwd_revision;
        }

        // Whether the observation still describes the pane's process, asked once: it reads the
        // terminal's foreground group with a system call.
        const bool current = entry.process_result && (entry.process_result->inspected || entry.process_result->ports_inspected) && observes(*pane, *entry.process_result);

        if (entry.process_result && entry.process_result->inspected) {
          TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_inspections));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(model.metrics.agent_process_misses, entry.process_result->provider == AgentProvider::unknown));
          model.pane_revision += current && applyProcess(agents, pane.getMut().core, *entry.process_result);
        }

        if (entry.process_result && entry.process_result->ports_inspected) {
          model.pane_revision += current && applyPorts(pane.getMut().core, *entry.process_result);
        }

        if (entry.screen.signal) {
          agents.observeScreen(pane.getMut().core, *entry.screen.signal, entry.screen.time);
        }
      }

      // The request shares the observers of region `a`.
      inline static void enqueueRetired(tbc::mut_a<RuntimeModel> model, tbc::mut_a<typename Processor::Request> request) noexcept {
        auto* link = &model.retired_observers;

        while (*link && request.count < request.entries.size()) {
          auto& observer = **link;
          if (observer.idle()) {
            auto next = std::move(observer.retiredNextMut());

            *link = std::move(next);
            --model.retired_observer_count;
            continue;
          }

          if (observer.seal()) {
            request.entries.atMut(request.count++).observer = *link;
          }

          link = &observer.retiredNextMut();
        }
      }

      // A sole pane discovers its foreground group on the worker; others read it here. A program's
      // listening ports are read again every `ports_interval`, output or not.
      inline void enqueue(tbc::mut_a<typename Processor::Request> request, const Agents& agents, tbc::mut_a<Pane> core, bool sole, std::chrono::steady_clock::time_point now) {
        PaneRef<TerminalBody> pane{.core = core, .body = *core.asMut<TerminalBody>()};

        if (const auto drop = pane.body.observer->takeDrop()) {
          limits_.report(*drop);
        }

        const bool probe_process = !pane.core.exit_status;
        // An agent's card shows no ports, so its pane is not read for them.
        const auto* agent = agents.find(pane.core.id, pane.core.generation);
        const bool ports_due = probe_process && agent == nullptr && !pane.core.foreground_shell && now - pane.core.ports_checked >= ports_interval;
        if (!pane.body.observer->seal(probe_process && (pane.core.process_recheck_requested || ports_due))) {
          return;
        }

        request.entries.atMut(request.count++) = {.pane = pane.core.id, .generation = pane.core.generation, .provider = AgentProvider::unknown, .observer = pane.body.observer, .probe_process = probe_process};
        auto& entry = request.entries.atMut(request.count - 1);

        entry.input_revision = pane.core.input_revision;
        entry.process_request = {pane.core.id, pane.core.generation, pane.core.cwd_revision, pane.core.process_id, 0};
        entry.process_request.cache = pane.core.process_cache;
        if (agent != nullptr) {
          entry.provider = agent->provider;
          entry.tracked_agent = true;
        }

        if (probe_process) {
          entry.process_request.discover_foreground = sole;
          if (!entry.process_request.discover_foreground) {
            entry.process_request.foreground = pane.body.process->foregroundProcessGroup().valueOr(0);
          }

          entry.process_request.recheck = pane.core.process_recheck_requested;
          entry.process_request.ports = ports_due;
          pane.core.process_recheck_running = pane.core.process_recheck_requested;
          pane.core.process_recheck_requested = false;
          if (ports_due) {
            pane.core.ports_checked = now;
          }
        }
      }

      inline static bool observes(PaneRef<TerminalBody> pane, const ProcessProbeResult& observation) {
        return pane.core.generation == observation.request.generation && !pane.core.exit_status && pane.core.process_id == observation.request.root && pane.body.process->foregroundProcessGroup().valueOr(0) == observation.request.foreground;
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
      using Result = std::expected<clipboard::Content, clipboard::ReadError>;

      static Result observe(const Request& /*request*/) noexcept;

      void stop() noexcept;
    };

    // One bounded capture at a time. Pulling one chunk per request keeps a slow
    // consumer from filling the response queue or stalling terminal delivery.
    // Kept whole: tests instantiate it with their own fake Reader (runtime_clipboard_test's Reader).
    template <typename Reader = RuntimeClipboardReader>
    class [[tbc::generic]] RuntimeClipboardService {
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
        worker_.collect([&](Reader::Result& result) {
          pending_ = false;
          auto* client = clients.find(owner_);
          if (client == nullptr || client->generation != generation_ || client->connection.flags().closing || Clock::now() >= expires_) {
            clear();
            return;
          }

          try {
            if (!result) {
              const auto code = result.error() == clipboard::ReadError::content_too_large ? FailureCode::resource_limit : FailureCode::invalid_request;

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
          if (now >= expires_ || client == nullptr || client->generation != generation_ || client->connection.flags().closing) {
            clear();
          }
        }
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

    private:
      inline static std::string_view errorMessage(clipboard::ReadError error) noexcept {
        if (error == clipboard::ReadError::content_too_large) {
          return "Clipboard exceeds clipboard.max_capture_bytes (33554432 bytes)";
        }

        return clipboard::errorMessage(error);
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
      clipboard::Content content_;
      std::uint64_t owner_ = 0;
      std::uint64_t generation_ = 0;
      std::uint64_t transfer_ = 0;
      std::size_t offset_ = 0;
      Clock::time_point expires_;
      bool pending_ = false;
    };

  }
}

// Interface: runtime/worktree_detection_service.cppm
export {
  namespace telar::runtime {

    // Kept whole: tests instantiate it with their own fake Probe (worktree_detection_test's GatedWorktreeDetector).
    template <WorktreeDetector Probe>
    class [[tbc::generic]] WorktreeDetectionService {
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
          if (pane->exit_status || pane->location.workspace.kind != WorkspaceLocation::Kind::workspace || !pane->cwd.view().starts_with('/') || model.worktrees.containing(pane->cwd) != nullptr) {
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
          const auto* pane = findPane(model.panes, {.id = result.pane, .generation = result.generation});
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
          } catch (const RequestError&) { // NOLINT(bugprone-empty-catch): a checkout the catalog refuses stays unlisted, as one never detected
          }
        });
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

    private:
      ObservationWorker<Probe> worker_;
      bool pending_ = false;
    };

  }
}
