module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.runtime.media_service;

import telar.runtime.model.slot_store;
import telar.runtime.platform.stream_read_buffer;
import telar.platform.error;
import telar.wire.agents;
import telar.base.ds;

namespace telar::runtime {

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::BackgroundPool(ConcurrentMemory& memory, History& history, Paths& paths, Editor& editor, Suggestions& suggestions)
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

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  std::array<int, 5> BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::descriptors() const noexcept {
    return {history_.descriptor(), path_service_.descriptor(), editor_.descriptor(), suggestions_.descriptor(), worktrees_.descriptor()};
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  bool BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::suggestionsAvailable() const noexcept {
    return suggestion_service_.available();
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  bool BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::editorBusy() noexcept {
    return editor_.pending();
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  bool BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::recordHistory(const HistoryEventView& event) noexcept {
    try {
      history_.submitInternal(event);
      return true;
    } catch (...) {
      history_submission_failures_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  std::uint64_t BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::takeHistoryFailures() noexcept {
    return history_submission_failures_.exchange(0, std::memory_order_relaxed) + history_.takeInternalFailures();
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  bool BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::observeWorktree(const WorktreeProbeRequest& request) {
    return worktrees_.submit(request);
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  void BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::cancel(std::uint64_t client) noexcept {
    history_.cancel(client);
    path_service_.cancel(client);
    editor_.cancel(client);
    suggestions_.cancel(client);
  }

#if TELAR_DIAGNOSTICS
  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  HistoryMetrics BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::historyMetrics() const noexcept
    requires requires(const History& service) { service.historyMetrics(); }
  {
    auto snapshot = history_service_.historyMetrics();

    snapshot.queue = history_.queueMetrics();
    snapshot.query_submissions = history_queries_;
    snapshot.query_refusals = history_query_failures_;
    return snapshot;
  }
#endif

  BackgroundService::BackgroundService(ConcurrentMemory& memory, const char* history_path, const HistoryFilters& filters)
      : history_(std::in_place_type<HistoryFilters>, filters),
#if TELAR_DIAGNOSTICS
        storage_(memory, history_path),
#endif
        decode_(AllocatorRef<Byte, ConcurrentMemory>{memory}) {
    decode_.resize(decode_capacity);
    try {
      history_.template emplace<HistoryStore>(memory, history_path, filters);
    } catch (const SystemError&) {
      throw;
    } catch (const RequestError& error) {
      if (error.code() != FailureCode::internal) {
        throw;
      }
    } catch (...) {
    }

    if (!std::holds_alternative<HistoryStore>(history_)) {
      history_.template emplace<HistoryFilters>(filters);
    }

    TELAR_DIAGNOSTIC(idle());
  }

  void BackgroundService::process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    TELAR_TRACE("background_service.process");
    TELAR_DIAGNOSTIC(idle());
    const bool known = ClientRequests::dispatch<RequestLane::service>(static_cast<ClientTag>(payload.front()), [&]<typename Message> {
      DecodeStorage storage{decode_};

      execute(Codec::decode<Message>(payload, storage), reply, context);
    });
    if (!known) {
      throw RequestError{FailureCode::invalid_request, "Unknown background request"};
    }
  }

  void BackgroundService::processInternal(const InternalRequest& request) {
    TELAR_DIAGNOSTIC(idle());
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{&counters_.writes});
    if (auto* store = std::get_if<HistoryStore>(&history_)) {
      try {
        store->record(request.view());
        return;
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
  }

  bool BackgroundService::acceptsInternal(const HistoryEventView& event) const noexcept {
    if (const auto* store = std::get_if<HistoryStore>(&history_)) {
      return store->accepts(event);
    }

    return event.kind != HistoryEventKind::command_finished || std::get<HistoryFilters>(history_).allowsPane(event.command.command, event.command.directory);
  }

#if TELAR_DIAGNOSTICS
  void BackgroundService::idle() noexcept {
    storage_.sample(diagnostics::FileStorage<ConcurrentMemory>::Clock::now());
  }

  HistoryMetrics BackgroundService::historyMetrics() const noexcept {
    auto snapshot = counters_.snapshot(std::holds_alternative<HistoryStore>(history_));

    snapshot.sqlite_bytes = storage_.bytes();
    return snapshot;
  }
#endif

  template <typename Message>
  void BackgroundService::execute(const Message& request, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context) {
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{counters_.template operation<Message>()});
    auto* store = std::get_if<HistoryStore>(&history_);
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
      } catch (const RequestError& error) {
        if (error.code() != FailureCode::internal) {
          throw;
        }
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
    replyHistoryFailure(request, reply, store != nullptr);
  }

  void DescriptionQueue::enable(bool enabled) noexcept {
    descriptions_enabled_ = enabled;
  }

  bool DescriptionQueue::enabled() const noexcept {
    return descriptions_enabled_;
  }

  std::size_t DescriptionQueue::pending(const AgentRegistry<ConcurrentMemory>& agents) noexcept {
    return static_cast<std::size_t>(std::ranges::count_if(agents.records(), [](const auto& entry) {
      return entry->hasPendingDescription();
    }));
  }

  void DescriptionQueue::project(std::size_t pending, Agent& agent) noexcept {
    if (descriptions_enabled_ && agent.description_phase == DescriptionPhase::waiting_work && pending < description_queue_capacity) {
      agent.queueDescription();
    }
  }

  ds::Option<DescriptionRequest> DescriptionQueue::nextDescription(AgentRegistry<ConcurrentMemory>& agents) {
    std::size_t pending = 0;

    for (const auto& agent : agents.records()) {
      if (agent->description_phase == DescriptionPhase::running) {
        return ds::none;
      }

      pending += agent->hasPendingDescription();
    }

    for (auto& agent : agents.records()) {
      if (pending < description_queue_capacity && agent->queueDescription()) {
        ++pending;
        agents.changed();
      }
    }

    for (auto& agent : agents.records()) {
      if (agent->description_phase != DescriptionPhase::queued) {
        continue;
      }

      try {
        auto query = agent->description_capture.normalized();

        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::running;
        agent->description_revision = ++description_revision_;
        return DescriptionRequest{.identity = {agent->pane, agent->generation, agent->session_id, agent->description_revision}, .query = std::move(query)};
      } catch (const EncodingError&) {
        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::failed;
        agent->title_state = AgentTitleState::failed;
        agents.changed();
      }
    }

    return ds::none;
  }

  ds::Option<HistorySessionTitle> DescriptionQueue::completeDescription(AgentRegistry<ConcurrentMemory>& agents, const DescriptionResult& result) {
    auto* agent = agents.find(result.identity.pane, result.identity.generation);
    if (agent == nullptr || agent->description_phase != DescriptionPhase::running || agent->session_id != result.identity.session || agent->description_revision != result.identity.revision) {
      return ds::none;
    }

    HistorySessionTitle finished{.session = agent->session_id};

    if (result.status == DescriptionStatus::success) {
      try {
        finished.title = normalizeDescriptionTitle(result.title.view());
        finished.source = AgentTitleSource::generated;
        finished.state = AgentTitleState::ready;
      } catch (const EncodingError&) {
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

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  MediaService<Poller, Limits, History>::MediaService(Poller& poller, Limits& limits)
      : poller_(poller),
        limits_(limits),
        worker_(std::in_place) {}

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::start(RuntimeModel& model, const ClientStore& clients, Panes& service) {
    if (pending_) {
      return;
    }

    typename Processor::Request request;

    enqueueRetired(model, request);
    const auto panes = model.panes.items();

    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      auto* pane = panes[next_slot_++ % panes.size()];
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
        pane->media->discardUnwantedTransfers([&](ImageKey key, bool shared) {
          return wanted(clients, pane->id, key, shared);
        });
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

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::collect(RuntimeModel& model, ClientStore& clients, Panes& service) {
    if (pending_) {
      worker_.collect([&](const typename Processor::Result& result) {
        apply(model, clients, service, result);
      });
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::updateReadInterest(Pane& pane) {
    if (pane.output_closed) {
      return;
    }

    const bool paused = pane.terminal.hasPendingControl() || pane.media->holdsRead(Pane::read_buffer_size);
    if (paused != pane.read_paused) {
      poller_.readInterest(pane.process->descriptor(), eventToken(EventSource::pane, pane.event_identity), !paused);
      pane.read_paused = paused;
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::finish(RuntimeModel& model) noexcept {
    for (auto* pane : model.panes.items()) {
      if (pane != nullptr) {
        pane->media->cancel();
      }
    }

    for (auto media = model.retired_media; media; media = media->retired_next) {
      media->cancel();
    }

    for (;;) {
      worker_.wait([&](const typename Processor::Result& result) {
        pending_ = false;
        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          entry.media->complete();
        }
      });

      typename Processor::Request request;

      enqueueRetired(model, request);
      for (auto* pane : model.panes.items()) {
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

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  int MediaService<Poller, Limits, History>::descriptor() const noexcept {
    return worker_.descriptor();
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  bool MediaService<Poller, Limits, History>::wanted(const ClientStore& clients, std::uint64_t pane, ImageKey key, bool shared) noexcept {
    for (const auto* client : clients.items()) {
      const auto* attachment = client == nullptr ? nullptr : client->attachment(pane);
      if (attachment != nullptr && attachment->graphics.wantsImage(key, shared)) {
        return true;
      }
    }

    return false;
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::enqueueRetired(tbc::view<RuntimeModel&, tbc::lt::a> model, tbc::view<typename Processor::Request&, tbc::lt::a> request) noexcept {
    auto* link = &model.retired_media;

    while (*link && request.count < request.entries.size()) {
      auto& media = **link;
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

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::apply(RuntimeModel& model, ClientStore& clients, Panes& service, const typename Processor::Result& result) {
    pending_ = false;
    for (const auto& entry : std::span{result.entries}.first(result.count)) {
      entry.media->complete();
      TELAR_DIAGNOSTIC(model.metrics.media.merge(entry.metrics));
    }

    for (const auto& entry : std::span{result.entries}.first(result.count)) {
      auto* pane = findPane(model.panes, entry.pane, entry.generation);
      if (pane == nullptr) {
        continue;
      }

      if (entry.media->failed()) {
        service.failOutput(*pane);
        continue;
      }

      if (entry.reset) {
        for (auto* client : clients.items()) {
          if (auto* attachment = client == nullptr ? nullptr : client->attachment(pane->id)) {
            attachment->graphics.requestSnapshot();
          }
        }
      }

      if (auto* terminal = pane->media->terminal()) {
        reportLimits(model.graphics_limits, *terminal);
        stageTransfers(clients, model.metrics, pane->id, terminal->graphics);
      }

      if (!pane->output_closed) {
        service.flushInput(*pane);
      }

      updateReadInterest(*pane);
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::stageTransfers(ClientStore& clients, [[maybe_unused]] diagnostics::RuntimeCounters& metrics, std::uint64_t pane, const GraphicsStorage<MediaAllocator<ConcurrentMemory>>& storage) {
    if (storage.revision() == 0) {
      return;
    }

    for (auto* client : clients.items()) {
      if (auto* attachment = client == nullptr ? nullptr : client->attachment(pane)) {
        attachment->graphics.stageAtMediaBoundary(storage);
        TELAR_DIAGNOSTIC(metrics.graphics.merge(attachment->graphics.takeCounters()));
      }
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::reportLimits(const GraphicsLimits& graphics, MediaTerminal& terminal) {
    auto& storage = terminal.graphics;
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

  template class BackgroundPool<BackgroundService, PathService<ConcurrentMemory>, EditorService, SuggestionService>;

  template class MediaService<NativeEventLoop<ConcurrentMemory>, LimitService, BackgroundPool<BackgroundService, PathService<ConcurrentMemory>, EditorService, SuggestionService>>;
  template class MediaService<NativeEventLoop<ConcurrentMemory>, LimitService>;

}
