module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>

#include <cstdint>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"
#include <cerrno>
#include <pthread.h>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <cassert>
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <sys/stat.h>

#include <sqlite3.h>


#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <csignal>
#include <sys/uio.h>
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

#include <dirent.h>

export module telar.runtime.runtime.media_service;

import std;

export import telar.runtime.history.event;
export import telar.runtime.platform.request_worker;
export import telar.runtime.worktrees.git_probe;


export import telar.runtime.history.store;
export import telar.runtime.runtime.background_executor;
export import telar.platform;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
#if (TELAR_DIAGNOSTICS)
export import telar.runtime.diagnostics.operation;
#endif


export import telar.runtime.agents.snapshot;


export import telar.runtime.agents.description_generator;


export import telar.runtime.graphics.synchronizer;
export import telar.runtime.runtime.execution_service;


export import telar.runtime.paths.query_task;


export import telar.runtime.workspaces.git_probe;

// Interface: runtime/background_pool.cppm
export {
namespace telar::runtime {

// The workers behind history, paths, editors, suggestions and worktrees, which the runtime's services
// and their own workers share: each queue it holds is synchronized, and what it hands a consumer lives
// for the callback.
template <ConcurrentAllocator Memory, typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees = WorktreeGitProbe<Memory>>
class TBC_SHARED BackgroundPool {
public:
  inline explicit BackgroundPool(Memory &memory, History &history, Paths &paths, Editor &editor, Suggestions &suggestions)
      : path_service_(paths),
        suggestion_service_(suggestions),
#if TELAR_DIAGNOSTICS
        history_service_(history),
#endif
        history_(memory, history),
        editor_(memory, editor),
        suggestions_(memory, suggestions),
        worktrees_(std::in_place, memory) {
  }

  inline std::array<int, 5> descriptors() const noexcept {
    return {history_.descriptor(), path_service_.descriptor(), editor_.descriptor(), suggestions_.descriptor(), worktrees_.descriptor()};
  }

  inline bool suggestionsAvailable() const noexcept {
    return suggestion_service_.available();
  }

  inline bool editorBusy() noexcept {
    return editor_.pending();
  }

  template <typename Message>
  inline void submit(std::uint64_t client, const Message &message, const RequestContext &context = {}) {
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

  template <typename Consumer>
  inline void collect(Consumer &&consumer) {
    history_.collect(consumer);
    path_service_.collect(consumer);
    editor_.collect(consumer);
    suggestions_.collect(consumer);
  }

  template <typename Reply>
  inline bool tryPaths(std::uint64_t client, const FindPaths &request, Reply &reply) {
    return path_service_.tryQuery(client, request, reply);
  }

  inline bool recordHistory(const HistoryEventView &event) noexcept {
    try {
      history_.submitInternal(event);
      return true;
    } catch (...) {
      history_submission_failures_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
  }

  inline std::uint64_t takeHistoryFailures() noexcept {
    return history_submission_failures_.exchange(0, std::memory_order_relaxed) + history_.takeInternalFailures();
  }

  inline bool observeWorktree(const WorktreeProbeRequest &request) {
    return worktrees_.submit(request);
  }

  template <typename Consumer>
  inline void collectWorktrees(Consumer &&consume) {
    worktrees_.collect(consume);
  }

  inline void cancel(std::uint64_t client) noexcept {
    history_.cancel(client);
    path_service_.cancel(client);
    editor_.cancel(client);
    suggestions_.cancel(client);
  }

#if TELAR_DIAGNOSTICS
  inline HistoryMetrics historyMetrics() const noexcept
    requires requires(const History &service) { service.historyMetrics(); }
  {
    auto snapshot = history_service_.historyMetrics();
    snapshot.queue = history_.queueMetrics();
    snapshot.query_submissions = history_queries_;
    snapshot.query_refusals = history_query_failures_;
    return snapshot;
  }
#endif

private:
  Paths &path_service_;
  Suggestions &suggestion_service_;
#if TELAR_DIAGNOSTICS
  History &history_service_;
  std::uint64_t history_queries_ = 0;
  std::uint64_t history_query_failures_ = 0;
#endif
  RequestWorker<Memory, History> history_;
  RequestWorker<Memory, Editor> editor_;
  RequestWorker<Memory, Suggestions> suggestions_;
  ObservationWorker<Worktrees> worktrees_;
  std::atomic<std::uint64_t> history_submission_failures_{0};
};

template <ConcurrentAllocator Memory, typename History, typename Paths, typename Editor, typename Suggestions>
BackgroundPool(Memory &memory, History &history, Paths &paths, Editor &editor, Suggestions &suggestions) -> BackgroundPool<Memory, History, Paths, Editor, Suggestions>;

}
}

// Interface: runtime/background_service.cppm
export {
#if TELAR_DIAGNOSTICS
#endif

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class BackgroundService {
public:
  using InternalRequest = HistoryEvent<Memory>;

  inline explicit BackgroundService(Memory &memory, const char *history_path, const HistoryFilters &filters = default_history_filters)
      : history_(std::in_place_type<HistoryFilters>, filters),
#if TELAR_DIAGNOSTICS
        storage_(memory, history_path),
#endif
        decode_(AllocatorRef<Byte, Memory>{memory}) {
    decode_.resize(decode_capacity);
    try {
      history_.template emplace<HistoryStore<Memory>>(memory, history_path, filters);
    } catch (const SystemError &) {
      throw;
    } catch (const RequestError &error) {
      if (error.code() != FailureCode::internal) {
        throw;
      }
    } catch (...) {
    }

    if (!std::holds_alternative<HistoryStore<Memory>>(history_)) {
      history_.template emplace<HistoryFilters>(filters);
    }
    TELAR_DIAGNOSTIC(idle());
  }

  inline void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    TELAR_TRACE("background_service.process");
    TELAR_DIAGNOSTIC(idle());
    DecodeStorage storage{decode_};
    switch (static_cast<ClientTag>(payload.front())) {
    case ClientTag::query_history:
      execute(Codec::decode<QueryHistory>(payload, storage), reply, context);
      return;
    case ClientTag::import_history:
      execute(Codec::decode<ImportHistory>(payload, storage), reply, context);
      return;
    case ClientTag::delete_history:
      execute(Codec::decode<DeleteHistory>(payload, storage), reply, context);
      return;
    case ClientTag::prune_history:
      execute(Codec::decode<PruneHistory>(payload, storage), reply, context);
      return;
    case ClientTag::read_history_output:
      execute(Codec::decode<ReadHistoryOutput>(payload, storage), reply, context);
      return;
    case ClientTag::history_stats:
      execute(Codec::decode<HistoryStatsQuery>(payload, storage), reply, context);
      return;
    case ClientTag::report_agent_command:
      execute(Codec::decode<ReportAgentCommand>(payload, storage), reply, context);
      return;
    default:
      throw RequestError{FailureCode::invalid_request, "Unknown background request"};
    }
  }

  inline void processInternal(const InternalRequest &request) {
    TELAR_DIAGNOSTIC(idle());
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{&counters_.writes});
    if (auto *store = std::get_if<HistoryStore<Memory>>(&history_)) {
      try {
        store->record(request.view());
        return;
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
  }

  inline bool acceptsInternal(const HistoryEventView &event) const noexcept {
    if (const auto *store = std::get_if<HistoryStore<Memory>>(&history_)) {
      return store->accepts(event);
    }

    return event.kind != HistoryEventKind::command_finished || std::get<HistoryFilters>(history_).allowsPane(event.command.command, event.command.directory);
  }

#if TELAR_DIAGNOSTICS
  inline void idle() noexcept {
    storage_.sample(diagnostics::FileStorage<Memory>::Clock::now());
  }

  inline HistoryMetrics historyMetrics() const noexcept {
    auto snapshot = counters_.snapshot(std::holds_alternative<HistoryStore<Memory>>(history_));
    snapshot.sqlite_bytes = storage_.bytes();
    return snapshot;
  }
#endif

private:
  template <typename Message>
  inline void execute(const Message &request, EncodedReply<Memory> &reply, const RequestContext &context) {
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{counters_.template operation<Message>()});
    auto *store = std::get_if<HistoryStore<Memory>>(&history_);
    if (store != nullptr) {
      try {
        if constexpr (std::same_as<Message, QueryHistory>) {
          store->query(request, reply);
        } else if constexpr (std::same_as<Message, ImportHistory>) {
          store->importEntries(request, reply);
        } else if constexpr (std::same_as<Message, DeleteHistory>) {
          store->remove(request, reply);
        } else if constexpr (std::same_as<Message, PruneHistory>) {
          store->prune(request, reply);
        } else if constexpr (std::same_as<Message, ReadHistoryOutput>) {
          store->readOutput(request, reply);
        } else if constexpr (std::same_as<Message, HistoryStatsQuery>) {
          store->stats(request, reply);
        } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
          store->reportAgentCommand(request, context, reply);
        }

        return;
      } catch (const RequestError &error) {
        if (error.code() != FailureCode::internal) {
          throw;
        }
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
    replyHistoryFailure(request, reply, store != nullptr);
  }

  static constexpr std::size_t decode_capacity = 128 * 1024;
  std::variant<HistoryFilters, HistoryStore<Memory>> history_;
#if TELAR_DIAGNOSTICS
  diagnostics::FileStorage<Memory> storage_;
#endif
  Vector<Byte, Memory> decode_;
  [[no_unique_address]] HistoryCounters counters_;
};

template <ConcurrentAllocator Memory>
BackgroundService(Memory &memory, const char *history_path, const HistoryFilters &filters = default_history_filters) -> BackgroundService<Memory>;

}
}

// Interface: runtime/description_queue.cppm
export {
namespace telar::runtime {

// Which agents' sessions get a generated title. It holds no agents; each call is given the registry.
template <Allocator Memory>
class DescriptionQueue {
public:
  inline void enable(bool enabled) noexcept {
    descriptions_enabled_ = enabled;
  }

  inline bool enabled() const noexcept {
    return descriptions_enabled_;
  }

  // How many descriptions are pending, which project reads before it changes an agent.
  inline static std::size_t pending(const AgentRegistry<Memory> &agents) noexcept {
    return static_cast<std::size_t>(std::ranges::count_if(agents.records(), [](const auto &entry) { return entry->hasPendingDescription(); }));
  }

  inline void project(std::size_t pending, Agent &agent) noexcept {
    if (descriptions_enabled_ && agent.description_phase == DescriptionPhase::waiting_work && pending < description_queue_capacity) {
      agent.queueDescription();
    }
  }

  inline std::optional<DescriptionRequest> nextDescription(AgentRegistry<Memory> &agents) {
    std::size_t pending = 0;
    for (const auto &agent : agents.records()) {
      if (agent->description_phase == DescriptionPhase::running) {
        return std::nullopt;
      }

      pending += agent->hasPendingDescription();
    }

    for (auto &agent : agents.records()) {
      if (pending < description_queue_capacity && agent->queueDescription()) {
        ++pending;
        agents.changed();
      }
    }

    for (auto &agent : agents.records()) {
      if (agent->description_phase != DescriptionPhase::queued) {
        continue;
      }

      try {
        auto query = agent->description_capture.normalized();
        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::running;
        agent->description_revision = ++description_revision_;
        return DescriptionRequest{.identity = {agent->pane, agent->generation, agent->session_id, agent->description_revision}, .query = std::move(query)};
      } catch (const EncodingError &) {
        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::failed;
        agent->title_state = AgentTitleState::failed;
        agents.changed();
      }
    }

    return std::nullopt;
  }

  inline std::optional<HistorySessionTitle> completeDescription(AgentRegistry<Memory> &agents, const DescriptionResult &result) {
    auto *agent = agents.find(result.identity.pane, result.identity.generation);
    if (agent == nullptr || agent->description_phase != DescriptionPhase::running || agent->session_id != result.identity.session || agent->description_revision != result.identity.revision) {
      return std::nullopt;
    }

    HistorySessionTitle finished{.session = agent->session_id};
    if (result.status == DescriptionStatus::success) {
      try {
        finished.title = normalizeDescriptionTitle(result.title.view());
        finished.source = AgentTitleSource::generated;
        finished.state = AgentTitleState::ready;
      } catch (const EncodingError &) {
      }
    }

    if (finished.state == AgentTitleState::ready) {
      agent->title = finished.title;
      agent->title_source = finished.source;
      agent->finishTitleCapture();
    } else {
      agent->description_phase = DescriptionPhase::failed;
    }

    agent->title_state = finished.state;
    agents.changed();
    return finished;
  }

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
concept DescriptionObserver = requires(Agents &agents, const DescriptionResult &result) {
  { agents.enableDescriptions(true) } noexcept -> std::same_as<void>;
  { agents.nextDescription() } -> std::same_as<std::optional<DescriptionRequest>>;
  { agents.completeDescription(result) } -> std::same_as<std::optional<HistorySessionTitle>>;
};

// Generates session descriptions on a worker; the agents it describes are lent to each call.
template <ConcurrentAllocator Memory, DescriptionObserver Agents, HistoryEventSink History>
class DescriptionService {
public:
  inline explicit DescriptionService(Memory &memory, History &history, const DescriptionOptions &options)
      : history_(history) {
    if (!options.arguments.empty()) {
      worker_.emplace(std::in_place, memory, options);
    }
  }

  inline bool enabled() const noexcept {
    return worker_.has_value();
  }

  inline void tick(Agents &agents) {
    if (!worker_) {
      return;
    }

    collect(agents);
    if (!pending_) {
      if (auto request = agents.nextDescription()) {
        pending_ = worker_->submit(*request);
      }
    }
  }

  inline void collect(Agents &agents) {
    if (!pending_) {
      return;
    }

    worker_->collect([&](const DescriptionResult &result) {
      pending_ = false;
      if (const auto title = agents.completeDescription(result)) {
        history_.recordHistory(HistoryEventView{.kind = HistoryEventKind::session_title, .session = {}, .title = *title});
      }
    });
  }

  inline int descriptor() const noexcept {
    return worker_ ? worker_->descriptor() : -1;
  }

private:
  History &history_;
  std::optional<ObservationWorker<DescriptionGenerator<Memory>>> worker_;
  bool pending_ = false;
};

}
}

// Interface: runtime/media_service.cppm
export {
namespace telar::runtime {

// Decodes pane media on a worker. The model, the clients and the pane service are lent to each call.
template <ConcurrentAllocator Memory, EventLoop Poller, typename Limits, HistoryEventSink History = DiscardedHistory>
class MediaService {
  using Processor = MediaProcessor<Memory>;
  using Panes = PaneService<Memory, Poller, History>;

public:
  inline explicit MediaService(Poller &poller, Limits &limits)
      : poller_(poller),
        limits_(limits),
        worker_(std::in_place) {}

  inline void start(RuntimeModel<Memory> &model, const ClientStore<Memory> &clients, Panes &service) {
    if (pending_) {
      return;
    }

    typename Processor::Request request;
    enqueueRetired(model, request);
    const auto panes = model.panes.items();
    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      auto *pane = panes[next_slot_++ % panes.size()];
      if (pane == nullptr) {
        continue;
      }
      if (pane->media->failed()) {
        if (!pane->output_closed) {
          service.failOutput(*pane);
        }
        continue;
      }

      if (!pane->media->busy()) {
        pane->media->discardUnwantedTransfers([&](ImageKey key, bool shared) { return wanted(clients, pane->id, key, shared); });
      }
      if (pane->media->seal()) {
        request.entries[request.count++] = {pane->id, pane->generation, pane->media};
      }
      updateReadInterest(*pane);
    }
    if (request.count != 0) {
      pending_ = worker_.submit(request);
    }
  }

  inline void collect(RuntimeModel<Memory> &model, ClientStore<Memory> &clients, Panes &service) {
    if (pending_) {
      worker_.collect([&](const typename Processor::Result &result) { apply(model, clients, service, result); });
    }
  }

  inline void updateReadInterest(Pane<Memory> &pane) {
    if (pane.output_closed) {
      return;
    }

    const bool paused = pane.terminal.hasPendingControl() || pane.media->holdsRead(Pane<Memory>::read_buffer_size);
    if (paused != pane.read_paused) {
      poller_.readInterest(pane.process->descriptor(), eventToken(EventSource::pane, pane.event_identity), !paused);
      pane.read_paused = paused;
    }
  }

  inline void finish(RuntimeModel<Memory> &model) noexcept {
    for (auto *pane : model.panes.items()) {
      if (pane != nullptr) {
        pane->media->cancel();
      }
    }
    for (auto media = model.retired_media; media; media = media->retired_next) {
      media->cancel();
    }
    for (;;) {
      worker_.wait([&](const typename Processor::Result &result) {
        pending_ = false;
        for (const auto &entry : std::span{result.entries}.first(result.count)) {
          entry.media->complete();
        }
      });

      typename Processor::Request request;
      enqueueRetired(model, request);
      for (auto *pane : model.panes.items()) {
        if (request.count == request.entries.size()) {
          break;
        }
        if (pane != nullptr && pane->media->seal()) {
          request.entries[request.count++] = {pane->id, pane->generation, pane->media};
        }
      }
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
  inline static bool wanted(const ClientStore<Memory> &clients, std::uint64_t pane, ImageKey key, bool shared) noexcept {
    for (const auto *client : clients.items()) {
      const auto *attachment = client == nullptr ? nullptr : client->attachment(pane);
      if (attachment != nullptr && attachment->graphics.wantsImage(key, shared)) {
        return true;
      }
    }
    return false;
  }

  inline static void enqueueRetired(RuntimeModel<Memory> &model, typename Processor::Request &request) noexcept {
    auto *link = &model.retired_media;
    while (*link && request.count < request.entries.size()) {
      auto &media = **link;
      if (media.idle()) {
        auto next = std::move(media.retired_next);
        *link = std::move(next);
        --model.retired_media_count;
        continue;
      }

      if (media.seal()) {
        request.entries[request.count++].media = *link;
      }
      link = &media.retired_next;
    }
  }

  inline void apply(RuntimeModel<Memory> &model, ClientStore<Memory> &clients, Panes &service, const typename Processor::Result &result) {
    pending_ = false;
    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      entry.media->complete();
      TELAR_DIAGNOSTIC(model.metrics.media.merge(entry.metrics));
    }

    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      auto *pane = model.panes.find(entry.pane);
      if (pane == nullptr || pane->generation != entry.generation) {
        continue;
      }
      if (entry.media->failed()) {
        service.failOutput(*pane);
        continue;
      }

      if (entry.reset) {
        for (auto *client : clients.items()) {
          if (auto *attachment = client == nullptr ? nullptr : client->attachment(pane->id)) {
            attachment->graphics.requestSnapshot();
          }
        }
      }

      if (auto *terminal = pane->media->terminal()) {
        reportLimits(model.graphics_limits, *terminal);
        stageTransfers(clients, model.metrics, pane->id, terminal->graphics);
      }
      if (!pane->output_closed) {
        service.flushInput(*pane);
      }
      updateReadInterest(*pane);
    }
  }

  inline static void stageTransfers(ClientStore<Memory> &clients, [[maybe_unused]] diagnostics::RuntimeCounters &metrics, std::uint64_t pane, const GraphicsStorage<MediaAllocator<Memory>> &storage) {
    if (storage.revision() == 0) {
      return;
    }

    for (auto *client : clients.items()) {
      if (auto *attachment = client == nullptr ? nullptr : client->attachment(pane)) {
        TELAR_DIAGNOSTIC(attachment->graphics.bindCounters(metrics.graphics));
        attachment->graphics.stageAtMediaBoundary(storage);
      }
    }
  }

  inline void reportLimits(const GraphicsLimits &graphics, MediaTerminal<MediaAllocator<Memory>> &terminal) {
    auto &storage = terminal.graphics;
    if (const auto images = storage.takeTrimmedImages()) {
      limits_.report(LimitReach{.name = "graphics.images_per_screen", .noun = "images", .value = graphics_image_count, .requested = images});
    }
    if (const auto placements = storage.takeTrimmedPlacements()) {
      limits_.report(LimitReach{.name = "graphics.placements_per_screen", .noun = "placements", .value = graphics_placement_count, .requested = placements});
    }

    const auto uploads = terminal.takeUploadLimits();
    if (uploads.chunks) {
      limits_.report(LimitReach{.name = "graphics.max_chunks_per_image", .noun = "chunks", .value = GraphicsLimits::maximum_chunks_per_image});
    }
    if (uploads.bytes) {
      limits_.report(LimitReach{.name = "graphics.max_image_bytes_per_screen", .noun = "bytes", .value = graphics.screenBytes()});
    }
  }

  Poller &poller_;
  Limits &limits_;
  ObservationWorker<Processor> worker_;
  std::size_t next_slot_ = 0;
  bool pending_ = false;
};

}
}

// Interface: runtime/path_service.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, typename Index = PathIndex<Memory>>
  requires PathSearchIndex<Index, Memory>
class PathService {
public:
  inline explicit PathService(Memory &memory)
      : memory_(memory),
        slots_{emptySlot(memory), emptySlot(memory), emptySlot(memory), emptySlot(memory)} {}

  inline ~PathService() {
    stop();
  }

  inline void stop() noexcept {
    for (auto &slot : slots_) {
      if (slot) {
        slot->index.stop();
      }
    }
  }

  inline int descriptor() const noexcept {
    return completion_.descriptor();
  }

  inline void submit(std::uint64_t client, const FindPaths &request) {
    auto &slot = acquire(client);
    slot.used = ++clock_;
    slot.rebuild |= request.refresh || slot.wanted.root.view() != request.root;
    slot.wanted.assign(request);
    slot.pending = true;
    advance(slot);
  }

  template <typename Reply>
  inline bool tryQuery(std::uint64_t client, const FindPaths &request, Reply &reply) {
    auto *slot = find(client);
    if (slot == nullptr || slot->building || slot->querying || slot->rebuild || !slot->index.canQueryInline(request)) {
      return false;
    }

    slot->used = ++clock_;
    slot->wanted.assign(request);
    slot->index.queryPublished(request, reply);
    return true;
  }

  template <typename Consumer>
  inline void collect(Consumer &&consume) {
    completion_.drain();
    for (auto &owned : slots_) {
      if (!owned) {
        continue;
      }

      auto &slot = *owned;
      slot.build_worker.collect([&](bool) {
        slot.building = false;
        slot.pending |= slot.answered_partial && !slot.querying;
      });
      slot.query_worker.collect([&](const typename PathQueryTask<Memory, Index>::Result &result) {
        slot.querying = false;
        slot.answered_partial = !result.complete;
        if (!result.complete && slot.index.complete() && !slot.rebuild) {
          slot.pending = true;
        }
        if (!slot.abandoned) {
          consume(slot.client, ClientTag::find_paths, result.payload);
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
    for (auto &slot : slots_) {
      if (!slot || slot->client != client) {
        continue;
      }

      slot->abandoned = true;
      slot->index.stop();
      completion_.notify();
      return;
    }
  }

private:
  struct Slot {
    inline explicit Slot(Memory &memory, CompletionSignal &completion, std::uint64_t client)
        : client(client),
          index(memory),
          build_worker(&completion, std::in_place, index),
          query_worker(&completion, std::in_place, memory, index) {}

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
    ObservationWorker<PathBuildTask<Index>> build_worker;
    ObservationWorker<PathQueryTask<Memory, Index>> query_worker;
  };

  inline static Owned<Slot, Memory> emptySlot(Memory &memory) noexcept {
    return {nullptr, AllocationDeleter<Slot, Memory>{memory}};
  }

  inline Slot *find(std::uint64_t client) const noexcept {
    for (const auto &slot : slots_) {
      if (slot && !slot->abandoned && slot->client == client) {
        return slot.get();
      }
    }
    return nullptr;
  }

  inline Slot &acquire(std::uint64_t client) {
    if (auto *slot = find(client)) {
      return *slot;
    }

    Owned<Slot, Memory> *selected = nullptr;
    for (auto &slot : slots_) {
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
    *selected = makeOwned<Slot>(memory_, memory_, completion_, client);
    return **selected;
  }

  inline static void advance(Slot &slot) {
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

  Memory &memory_;
  CompletionSignal completion_;
  std::array<Owned<Slot, Memory>, 4> slots_;
  std::uint64_t clock_ = 0;
};

template <ConcurrentAllocator Memory>
PathService(Memory &memory) -> PathService<Memory>;

}
}

// Interface: runtime/workspace_git_service.cppm
export {
namespace telar::runtime {

template <Allocator Memory, WorkspaceGitObserver Probe>
class WorkspaceGitService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto probe_interval = std::chrono::seconds{5};

  // The probe is built in place on its worker from the arguments.
  template <typename... Arguments>
  inline explicit WorkspaceGitService(LimitService<Memory> &limits, Arguments &&...probe)
      : limits_(limits),
        worker_(std::in_place, std::forward<Arguments>(probe)...) {}

  inline std::chrono::nanoseconds tick(RuntimeModel<Memory> &model, Clock::time_point now) {
    collect(model, now);
    if (pending_) {
      return probe_interval;
    }
    if (now < next_check_ && checked_revision_ == model.workspace_revision) {
      return next_check_ - now;
    }

    Workspace<Memory> *oldest = nullptr;
    next_check_ = now + probe_interval;
    checked_revision_ = model.workspace_revision;
    for (auto *workspace : model.workspaces.items()) {
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

  inline void collect(RuntimeModel<Memory> &model, Clock::time_point now) {
    worker_.collect([&](const WorkspaceGitResult &result) {
      if (pending_ != result.identity) {
        return;
      }

      pending_.reset();
      next_check_ = now;
      auto *workspace = model.workspaces.find(result.identity);
      if (workspace == nullptr) {
        return;
      }

      if (result.timed_out && !workspace->git_timed_out) {
        limits_.report(LimitReach{.name = "gitstatus.status_timeout", .noun = "milliseconds", .value = std::chrono::duration_cast<std::chrono::milliseconds>(git_status_timeout).count()});
      }
      workspace->git_timed_out = result.timed_out;
      workspace->git_checked_at = now;
      const auto branch = result.present ? result.branch.view() : std::string_view{};
      const bool dirty = result.present && result.dirty.value_or(workspace->git_dirty);
      if (workspace->git_branch.view() != branch || workspace->git_dirty != dirty) {
        workspace->git_branch.assign(branch);
        workspace->git_dirty = dirty;
        ++model.workspace_revision;
      }
    });
  }

  inline int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  LimitService<Memory> &limits_;
  ObservationWorker<Probe> worker_;
  std::optional<std::uint64_t> pending_;
  Clock::time_point next_check_{};
  std::uint64_t checked_revision_ = 0;
};

}
}
