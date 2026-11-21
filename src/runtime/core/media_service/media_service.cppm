module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.core.media_service;

import std;
import telar.tbc;

import telar.runtime.history.event;
import telar.runtime.workers.request_worker;
import telar.runtime.workspaces.worktrees.git_probe;

import telar.runtime.history.store;
import telar.runtime.workers.background_executor;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.wire.history;
import telar.platform.primitives;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
#if (TELAR_DIAGNOSTICS)
import telar.runtime.diagnostics.operation;
#endif

import telar.runtime.agents.snapshot;

import telar.runtime.agents.description_generator;

import telar.runtime.terminal.graphics.synchronizer;
import telar.runtime.core.execution_service;

import telar.runtime.paths.query_task;

import telar.runtime.workspaces.git_probe;

import telar.runtime.core.delivery.client_delivery;
import telar.config.core;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.runtime.diagnostics.runtime_counters;
import telar.runtime.terminal.graphics.pane_media;
import telar.runtime.core.model.client_layouts;
import telar.runtime.host.event_loop;
import telar.runtime.host.signals;
import telar.runtime.terminal.graphics_storage;
import telar.runtime.transport.connection;
import telar.base.diagnostics;
import telar.runtime.workspaces.git_status;
import telar.base.ds;

// Interface: runtime/background_pool.cppm
export {
  namespace telar::runtime {

    // The workers a background pool runs, one descriptor each: history, paths, editors, suggestions and worktrees.
    inline constexpr std::size_t background_worker_count = 5;

    // The workers behind history, paths, editors, suggestions and worktrees, which the runtime's services
    // and their own workers share: each queue it holds is synchronized, and what it hands a consumer lives
    // for the callback.
    template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees = WorktreeGitProbe>
    class TBC_SHARED BackgroundPool {
    public:
      explicit BackgroundPool(ConcurrentMemory& memory, History& history, Paths& paths, Editor& editor, Suggestions& suggestions);

      ds::Array<int, background_worker_count> descriptors() const noexcept;

      bool suggestionsAvailable() const noexcept;

      bool editorBusy() noexcept;

      // Kept here: the message is any of the protocol's, an open set no unit can instantiate ahead.
      template <typename Message>
      TBC_GENERIC inline void submit(std::uint64_t client, const Message& message, const RequestContext& context = {}) {
        if constexpr (std::same_as<Message, FindPaths>) {
          path_service_.submit(client, message);
        } else if constexpr (std::same_as<Message, OpenEditor>) {
          editor_.submit(client, message, context);
        } else if constexpr (std::same_as<Message, SuggestCommand>) {
          suggestions_.submit(client, message, context);
        } else if constexpr (std::same_as<Message, QueryHistory>) {
          try {
            history_.submit(client, message, context);
            TELAR_DIAGNOSTIC(++history_queries_);
          } catch (...) {
            TELAR_DIAGNOSTIC(++history_query_failures_);
            throw;
          }
        } else {
          history_.submit(client, message, context);
        }
      }

      // Kept here: the consumer is the caller's callable, an open set no unit can instantiate ahead.
      template <typename Consumer>
      TBC_GENERIC inline void collect(const Consumer& consumer) {
        history_.collect(consumer);
        path_service_.collect(consumer);
        editor_.collect(consumer);
        suggestions_.collect(consumer);
      }

      // Kept here: the reply is the caller's, an open set no unit can instantiate ahead.
      template <typename Reply>
      TBC_GENERIC inline bool tryPaths(std::uint64_t client, const FindPaths& request, Reply& reply) {
        return path_service_.tryQuery(client, request, reply);
      }

      bool recordHistory(const HistoryEventView& event) noexcept;

      std::uint64_t takeHistoryFailures() noexcept;

      bool observeWorktree(const WorktreeProbeRequest& request);

      // Kept here: the consumer is the caller's callable, an open set no unit can instantiate ahead.
      template <typename Consumer>
      TBC_GENERIC inline void collectWorktrees(Consumer&& consume) {
        worktrees_.collect(std::forward<Consumer>(consume));
      }

      void cancel(std::uint64_t client) noexcept;

#if TELAR_DIAGNOSTICS
      HistoryMetrics historyMetrics() const noexcept
        requires requires(const History& service) { service.historyMetrics(); };
#endif

    private:
      Paths& path_service_;
      Suggestions& suggestion_service_;
#if TELAR_DIAGNOSTICS
      History& history_service_;
      std::uint64_t history_queries_ = 0;
      std::uint64_t history_query_failures_ = 0;
#endif
      RequestWorker<ConcurrentMemory, History> history_;
      RequestWorker<ConcurrentMemory, Editor> editor_;
      RequestWorker<ConcurrentMemory, Suggestions> suggestions_;
      ObservationWorker<Worktrees> worktrees_;
      std::atomic<std::uint64_t> history_submission_failures_{0};
    };

    template <typename History, typename Paths, typename Editor, typename Suggestions>
    BackgroundPool(ConcurrentMemory& memory, History& history, Paths& paths, Editor& editor, Suggestions& suggestions) -> BackgroundPool<History, Paths, Editor, Suggestions>;

  }
}

// Interface: runtime/background_service.cppm
export {
#if TELAR_DIAGNOSTICS
#endif

  namespace telar::runtime {

    class BackgroundService {
    public:
      using InternalRequest = HistoryEvent;

      explicit BackgroundService(ConcurrentMemory& memory, const char* history_path, const HistoryFilters& filters = defaultHistoryFilters());

      void process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context = {});

      void processInternal(const InternalRequest& request);

      bool acceptsInternal(const HistoryEventView& event) const noexcept;

#if TELAR_DIAGNOSTICS
      void idle() noexcept;

      HistoryMetrics historyMetrics() const noexcept;
#endif

    private:
      template <typename Message>
      void execute(const Message& request, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context);

      static constexpr std::size_t decode_capacity = std::size_t{128} * 1024;
      std::variant<HistoryFilters, HistoryStore> history_;
#if TELAR_DIAGNOSTICS
      diagnostics::FileStorage<ConcurrentMemory> storage_;
#endif
      ds::Vec<Byte, ConcurrentMemory> decode_;
      [[no_unique_address]] HistoryCounters counters_;
    };

  }
}

// Interface: runtime/description_queue.cppm
export {
  namespace telar::runtime {

    // Which agents' sessions get a generated title. It holds no agents; each call is given the registry.
    class DescriptionQueue {
    public:
      void enable(bool enabled) noexcept;

      [[nodiscard]] bool enabled() const noexcept;

      // How many descriptions are pending, which project reads before it changes an agent.
      static std::size_t pending(const AgentRegistry<ConcurrentMemory>& agents) noexcept;

      void project(std::size_t pending, Agent& agent) noexcept;

      ds::Option<DescriptionRequest> nextDescription(AgentRegistry<ConcurrentMemory>& agents);

      static ds::Option<HistorySessionTitle> completeDescription(AgentRegistry<ConcurrentMemory>& agents, const DescriptionResult& result);

    private:
      static constexpr std::size_t description_queue_capacity = 8;
      std::uint64_t description_revision_ = 0;
      bool descriptions_enabled_ = false;
    };

  }
}

// Interface: runtime/description_service.cppm
export {
  namespace telar::runtime {

    template <typename Agents>
    concept DescriptionObserver = requires(Agents& agents, const DescriptionResult& result) {
      { agents.enableDescriptions(true) } noexcept -> std::same_as<void>;
      { agents.nextDescription() } -> std::same_as<ds::Option<DescriptionRequest>>;
      { agents.completeDescription(result) } -> std::same_as<ds::Option<HistorySessionTitle>>;
    };

    // Generates session descriptions on a worker; the agents it describes are lent to each call.
    // Kept whole: Agents is the runtime's AgentService, from a module that imports this one.
    template <ConcurrentAllocator Memory, DescriptionObserver Agents, HistoryEventSink History>
    class TBC_GENERIC DescriptionService {
    public:
      inline explicit DescriptionService(Memory& memory, History& history, const DescriptionOptions& options)
          : history_(history) {
        if (!options.arguments.empty()) {
          worker_.emplace(std::in_place, memory, options);
        }
      }

      [[nodiscard]] inline bool enabled() const noexcept {
        return worker_.hasValue();
      }

      // Not inlined: publish() calls it on every wake, and its locals in publish()'s frame would span stack
      // pages that each cost a page fault after a pane's fork() (see Connection::read).
      [[gnu::noinline]] inline void tick(Agents& agents) {
        if (!worker_) {
          return;
        }

        collect(agents);
        if (!pending_) {
          if (auto request = agents.nextDescription()) {
            pending_ = worker_.getMut().submit(*request);
          }
        }
      }

      inline void collect(Agents& agents) {
        if (!pending_) {
          return;
        }

        worker_.getMut().collect([&](const DescriptionResult& result) {
          pending_ = false;
          if (const auto title = agents.completeDescription(result)) {
            history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::session_title, .session = {}, .title = *title});
          }
        });
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_ ? worker_->descriptor() : -1;
      }

    private:
      History& history_;
      ds::Option<ObservationWorker<DescriptionGenerator<Memory>>> worker_;
      bool pending_ = false;
    };

  }
}

// Interface: runtime/media_service.cppm
export {
  namespace telar::runtime {

    // Decodes pane media on a worker. The model, the clients and the pane service are lent to each call.
    template <EventLoop Poller, typename Limits, HistoryEventSink History = DiscardedHistory>
    class MediaService {
      using Processor = MediaProcessor;
      using Panes = PaneService<Poller, History>;

    public:
      explicit MediaService(Poller& poller, Limits& limits);

      void start(RuntimeModel& model, const ClientStore& clients, Panes& service);

      void collect(RuntimeModel& model, ClientStore& clients, Panes& service);

      void updateReadInterest(TerminalPane& pane);

      void finish(RuntimeModel& model) noexcept;

      int descriptor() const noexcept;

    private:
      static bool wanted(const ClientStore& clients, std::uint64_t pane, ImageKey key, bool shared) noexcept;

      // The request shares the model's retired media, and so what that media keeps: region `a`.
      static void enqueueRetired(tbc::mut_a<RuntimeModel> model, tbc::mut_a<typename Processor::Request> request) noexcept;

      void apply(RuntimeModel& model, ClientStore& clients, Panes& service, const Processor::Result& result);

      static void stageTransfers(ClientStore& clients, [[maybe_unused]] diagnostics::RuntimeCounters& metrics, std::uint64_t pane, const GraphicsStorage<MediaAllocator<ConcurrentMemory>>& storage);

      void reportLimits(const GraphicsLimits& graphics, MediaTerminal& terminal);

      Poller& poller_;
      Limits& limits_;
      ObservationWorker<Processor> worker_;
      std::size_t next_slot_ = 0;
      bool pending_ = false;
    };

  }
}

// Interface: runtime/path_service.cppm
export {
  namespace telar::runtime {

    // Kept whole: tests instantiate it with their own fake Index and Memory (path_service_test's GatedPathIndex).
    template <ConcurrentAllocator Memory, typename Index = PathIndex>
      requires PathSearchIndex<Index, Memory>
    class TBC_GENERIC PathService {
    public:
      inline explicit PathService(Memory& memory)
          : memory_(memory),
            slots_() {}

      inline ~PathService() {
        stop();
      }

      PathService(const PathService&) = delete;
      PathService& operator=(const PathService&) = delete;
      PathService(PathService&&) = delete;
      PathService& operator=(PathService&&) = delete;

      inline void stop() noexcept {
        for (auto& slot : slots_.viewMut()) {
          if (slot) {
            slot.getMut().index.stop();
          }
        }
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return completion_.descriptor();
      }

      inline void submit(std::uint64_t client, const FindPaths& request) {
        auto& slot = acquire(client);

        slot.used = ++clock_;
        slot.rebuild |= request.refresh || slot.wanted.root.view() != request.root;
        slot.wanted.assign(request);
        slot.pending = true;
        advance(slot);
      }

      template <typename Reply>
      inline bool tryQuery(std::uint64_t client, const FindPaths& request, Reply& reply) {
        auto* slot = findMut(client);
        if (slot == nullptr || slot->building || slot->querying || slot->rebuild || !slot->index.canQueryInline(request)) {
          return false;
        }

        slot->used = ++clock_;
        slot->wanted.assign(request);
        slot->index.queryPublished(request, reply);
        return true;
      }

      template <typename Consumer>
      inline void collect(const Consumer& consume) {
        completion_.drain();
        for (auto& owned : slots_.viewMut()) {
          if (!owned) {
            continue;
          }

          auto& slot = owned.getMut();

          // Each completion captures the slot's fields it changes, apart from the worker it is handed
          // to, as a Rust 2021 closure captures disjoint fields.
          slot.build_worker.collect([&building = slot.building, &pending = slot.pending, &answered_partial = slot.answered_partial, &querying = slot.querying](bool) {
            building = false;
            pending |= answered_partial && !querying;
          });

          slot.query_worker.collect([&querying = slot.querying, &answered_partial = slot.answered_partial, &pending = slot.pending, &index = std::as_const(slot.index), rebuild = slot.rebuild, abandoned = slot.abandoned, client = slot.client, &consume](const PathQueryTask<Memory, Index>::Result& result) {
            querying = false;
            answered_partial = !result.complete;
            if (!result.complete && index.complete() && !rebuild) {
              pending = true;
            }

            if (!abandoned) {
              consume(client, ClientTag::find_paths, result.payload);
            }
          });

          if (slot.abandoned) {
            if (!slot.building && !slot.querying) {
              owned.reset();
            }
          } else {
            advance(slot);
          }
        }
      }

      inline void cancel(std::uint64_t client) noexcept {
        for (auto& slot : slots_.viewMut()) {
          if (!slot || slot->client != client) {
            continue;
          }

          slot.getMut().abandoned = true;
          slot.getMut().index.stop();
          completion_.notify();
          return;
        }
      }

    private:
      struct Slot {
        inline explicit Slot(Memory& memory, CompletionSignal& completion, std::uint64_t owner)
            : client(owner),
              index(memory),
              build_worker(&completion, std::in_place, index),
              query_worker(&completion, std::in_place, memory, index) {}

        // The workers keep the slot's index, so the slot stays where it was built.
        Slot(const Slot&) = delete;
        Slot& operator=(const Slot&) = delete;
        Slot(Slot&&) = delete;
        Slot& operator=(Slot&&) = delete;
        ~Slot() = default;

        std::uint64_t client;
        std::uint64_t used = 0;
        OwnedPathQuery wanted;
        bool pending = false;
        bool rebuild = false;
        bool building = false;
        bool querying = false;
        bool answered_partial = false;
        bool abandoned = false;
        Index index;
        tbc::val_self<ObservationWorker<PathBuildTask<Index>>> build_worker;
        tbc::val_self<ObservationWorker<PathQueryTask<Memory, Index>>> query_worker;
      };

      inline Slot* findMut(std::uint64_t client) noexcept {
        for (auto& slot : slots_.viewMut()) {
          if (slot && !slot->abandoned && slot->client == client) {
            return &slot.getMut();
          }
        }

        return nullptr;
      }

      inline Slot& acquire(std::uint64_t client) {
        if (auto* slot = findMut(client)) {
          return *slot;
        }

        ds::Box<Slot, Memory>* selected = nullptr;

        for (auto& slot : slots_.viewMut()) {
          if (!slot) {
            selected = &slot;
            break;
          }

          if (!slot->building && !slot->querying && (selected == nullptr || slot->used < (*selected)->used)) {
            selected = &slot;
          }
        }

        if (selected == nullptr) {
          throw RequestError{FailureCode::resource_limit, "Every path picker slot is busy"};
        }

        selected->reset();
        *selected = ds::makeBox<Slot>(memory_, memory_, completion_, client);
        return selected->getMut();
      }

      inline static void advance(Slot& slot) {
        if (slot.rebuild) {
          if (slot.building || slot.querying) {
            slot.index.stop();
            return;
          }

          slot.index.reset(slot.wanted.root.view());
          slot.rebuild = false;
          slot.answered_partial = false;
          slot.building = slot.build_worker.submit(true);
        }

        if (slot.pending && !slot.querying) {
          slot.querying = slot.query_worker.submit(slot.wanted);
          slot.pending = !slot.querying;
        }
      }

      Memory& memory_;
      CompletionSignal completion_;
      ds::Array<ds::Box<Slot, Memory>, 4> slots_;
      std::uint64_t clock_ = 0;
    };

    template <ConcurrentAllocator Memory>
    PathService(Memory& memory) -> PathService<Memory>;

    // The runtime's pool and media service, which name the services above.
    extern template class BackgroundPool<BackgroundService, PathService<ConcurrentMemory>, EditorService, SuggestionService>;

    extern template class MediaService<NativeEventLoop<ConcurrentMemory>, LimitService, BackgroundPool<BackgroundService, PathService<ConcurrentMemory>, EditorService, SuggestionService>>;
    extern template class MediaService<NativeEventLoop<ConcurrentMemory>, LimitService>;

  }
}

// Interface: runtime/workspace_git_service.cppm
export {
  namespace telar::runtime {

    // Kept whole: tests instantiate it with their own fake Probe (workspace_git_test's ControlledGitProbe).
    template <WorkspaceGitObserver Probe>
    class TBC_GENERIC WorkspaceGitService {
    public:
      using Clock = std::chrono::steady_clock;
      static constexpr auto probe_interval = std::chrono::seconds{5};

      // The probe is built in place on its worker from the arguments.
      template <typename... Arguments>
      inline explicit WorkspaceGitService(LimitService& limits, Arguments&&... probe)
          : limits_(limits),
            worker_(std::in_place, std::forward<Arguments>(probe)...) {}

      // Not inlined: publish() calls it on every wake, and its locals in publish()'s frame would span stack
      // pages that each cost a page fault after a pane's fork() (see Connection::read).
      [[gnu::noinline]] inline std::chrono::nanoseconds tick(RuntimeModel& model, Clock::time_point now) {
        collect(model, now);
        if (pending_) {
          return probe_interval;
        }

        if (now < next_check_ && checked_revision_ == model.workspace_revision) {
          return next_check_ - now;
        }

        const Workspace* oldest = nullptr;

        next_check_ = now + probe_interval;
        checked_revision_ = model.workspace_revision;
        for (const auto* workspace : model.workspaces.items()) {
          if (workspace == nullptr) {
            continue;
          }

          const auto due = workspace->git_checked_at + probe_interval;

          next_check_ = std::min(next_check_, due);
          if (due <= now && (oldest == nullptr || workspace->git_checked_at < oldest->git_checked_at)) {
            oldest = workspace;
          }
        }

        if (oldest != nullptr) {
          WorkspaceGitRequest request{.identity = oldest->id};

          request.path.assign(oldest->path);
          if (worker_.submit(request)) {
            pending_ = oldest->id;
          }

          return probe_interval;
        }

        return next_check_ - now;
      }

      inline void collect(RuntimeModel& model, Clock::time_point now) {
        worker_.collect([&](const WorkspaceGitResult& result) {
          if (pending_ != result.identity) {
            return;
          }

          pending_.reset();
          next_check_ = now;
          auto* workspace = model.workspaces.find(result.identity);
          if (workspace == nullptr) {
            return;
          }

          if (result.timed_out && !workspace->git_timed_out) {
            limits_.report(LimitReach{.name = "gitstatus.status_timeout", .noun = "milliseconds", .value = std::chrono::duration_cast<std::chrono::milliseconds>(git_status_timeout).count()});
          }

          workspace->git_timed_out = result.timed_out;
          workspace->git_checked_at = now;
          const auto branch = result.present ? result.branch.view() : std::string_view{};
          const bool dirty = result.present && result.dirty.valueOr(workspace->git_dirty);
          if (workspace->git_branch.view() != branch || workspace->git_dirty != dirty) {
            workspace->git_branch.assign(branch);
            workspace->git_dirty = dirty;
            ++model.workspace_revision;
          }
        });
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

    private:
      LimitService& limits_;
      ObservationWorker<Probe> worker_;
      ds::Option<std::uint64_t> pending_;
      Clock::time_point next_check_;
      std::uint64_t checked_revision_ = 0;
    };

  }
}
