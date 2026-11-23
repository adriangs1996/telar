module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_platform/trace_macro.hpp"

module telar.runtime.core.media_service;

import telar.runtime.core.model.slot_store;
import telar.runtime.host.stream_read_buffer;
import telar.platform.error;
import telar.wire.agents;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // Each client attached to the pane is sent the pane's images whole again.
    void requestGraphicsSnapshots(std::span<ClientSession* const> clients, std::uint64_t pane) {
      for (auto* client : clients) {
        if (auto* attachment = client == nullptr ? nullptr : client->attachmentMut(pane)) {
          attachment->graphics.requestSnapshot();
        }
      }
    }

  }

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
        file_service_(memory),
        files_(memory, file_service_),
        worktrees_(std::in_place, memory) {
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  ds::Array<int, background_worker_count> BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::descriptors() const noexcept {
    return {history_.descriptor(), path_service_.descriptor(), editor_.descriptor(), suggestions_.descriptor(), files_.descriptor(), worktrees_.descriptor()};
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
    // A command a pane finished names the files it touched.
    if (event.kind == HistoryEventKind::command_finished) {
      constexpr std::int64_t second_ms = 1000;

      noteTouch({
          .pane = event.session.pane,
          .actor = event.command.author == HistoryAuthor::agent ? TouchActor::agent : TouchActor::user,
          .text = event.command.command,
          .directory = event.command.directory,
          .seconds = static_cast<std::uint64_t>(std::max<std::int64_t>(0, event.finished_at_ms) / second_ms),
      });
    }

    try {
      history_.submitInternal(event);
      return true;
    } catch (...) {
      history_submission_failures_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
  }

  template <typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees>
  void BackgroundPool<History, Paths, Editor, Suggestions, Worktrees>::noteTouch(const TouchNote& note) noexcept {
    file_service_.touches().note(note);
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
    files_.cancel(client);
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
        decode_(memory) {
    decode_.resize(decode_capacity);
    try {
      history_.template emplace<HistoryStore>(memory, history_path, filters);
    } catch (const SystemError&) {
      throw;
    } catch (const RequestError& error) {
      if (error.code() != FailureCode::internal) {
        throw;
      }
    } catch (...) { // NOLINT(bugprone-empty-catch): a history that cannot open leaves no store; the filters below stand in for it
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
      DecodeStorage storage{decode_.viewMut()};

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
      } catch (...) { // NOLINT(bugprone-empty-catch): a record the store cannot write is counted below as a failed write
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
  }

  bool BackgroundService::acceptsInternal(const HistoryEventView& event) const noexcept {
    if (const auto* store = std::get_if<HistoryStore>(&history_)) {
      return store->accepts(event);
    }

    // Without a store the service holds its filters; a history holding neither broke an invariant, which
    // stops the runtime as the throw out of this noexcept function did.
    const auto* filters = std::get_if<HistoryFilters>(&history_);
    if (filters == nullptr) {
      std::abort();
    }

    return event.kind != HistoryEventKind::command_finished || filters->allowsPane(event.command.command, event.command.directory);
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
    auto* store = std::get_if<HistoryStore>(&history_); // NOLINT(misc-const-correctness): most requests write the store's database, which only some instantiations of this template show
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
        } else if constexpr (std::same_as<Message, QueryHistoryWorkspaces>) {
          store->workspaces(request, reply);
        } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
          store->reportAgentCommand(request, context, reply);
        } else {
          static_assert(false, "BackgroundService::execute has no branch for this history request");
        }

        return;
      } catch (const RequestError& error) {
        if (error.code() != FailureCode::internal) {
          throw;
        }
      } catch (...) { // NOLINT(bugprone-empty-catch): any other failure is answered below as the history being unavailable
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

      pending += static_cast<std::size_t>(agent->hasPendingDescription());
    }

    // The registry learns of the change once its records are no longer borrowed.
    bool queued = false;

    for (auto& agent : agents.recordsMut()) {
      if (pending < description_queue_capacity && agent.getMut().queueDescription()) {
        ++pending;
        queued = true;
      }
    }

    if (queued) {
      agents.changed();
    }

    for (auto& agent : agents.recordsMut()) {
      if (agent->description_phase != DescriptionPhase::queued) {
        continue;
      }

      try {
        auto query = agent->description_capture.normalized();

        agent.getMut().description_capture.clear();
        agent.getMut().description_phase = DescriptionPhase::running;
        agent.getMut().description_revision = ++description_revision_;
        return DescriptionRequest{.identity = {.pane = agent->pane, .generation = agent->generation, .session = agent->session_id, .revision = agent->description_revision}, .query = std::move(query)};
      } catch (const EncodingError&) {
        agent.getMut().description_capture.clear();
        agent.getMut().description_phase = DescriptionPhase::failed;
        agent.getMut().title_state = AgentTitleState::failed;
        agents.changed();
      }
    }

    return ds::none;
  }

  ds::Option<HistorySessionTitle> DescriptionQueue::completeDescription(AgentRegistry<ConcurrentMemory>& agents, const DescriptionResult& result) {
    auto* agent = agents.findMut(result.identity.pane, result.identity.generation);
    if (agent == nullptr || agent->description_phase != DescriptionPhase::running || agent->session_id != result.identity.session || agent->description_revision != result.identity.revision) {
      return ds::none;
    }

    HistorySessionTitle finished{.session = agent->session_id};

    if (result.status == DescriptionStatus::success) {
      try {
        finished.title = normalizeDescriptionTitle(result.title.view());
        finished.source = AgentTitleSource::generated;
        finished.state = AgentTitleState::ready;
      } catch (const EncodingError&) { // NOLINT(bugprone-empty-catch): a title that does not normalize leaves the description failed, as below
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

    Processor::Request request;

    enqueueRetired(model, request);
    const auto panes = model.panes.items();

    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      const auto pane = asTerminal(panes[next_slot_++ % panes.size()]);
      if (!pane) {
        continue;
      }

      if (pane->body.media->failed()) {
        if (!pane->core.output_closed) {
          service.failOutput(*pane);
        }

        continue;
      }

      if (!pane->body.media->busy()) {
        pane->body.media->discardUnwantedTransfers([&](ImageKey key, bool shared) {
          return wanted(clients, pane->core.id, key, shared);
        });
      }

      if (pane->body.media->seal()) {
        request.entries.atMut(request.count++) = {.pane = pane->core.id, .generation = pane->core.generation, .media = pane->body.media};
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
      worker_.collect([&](const Processor::Result& result) {
        apply(model, clients, service, result);
      });
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::updateReadInterest(PaneRef<TerminalBody> pane) {
    if (pane.core.output_closed) {
      return;
    }

    const bool paused = pane.body.terminal.hasPendingControl() || pane.body.media->holdsRead(TerminalBody::read_buffer_size);
    if (paused != pane.core.read_paused) {
      poller_.readInterest(pane.body.process->descriptor(), eventToken(EventSource::pane, pane.core.event_identity), !paused);
      pane.core.read_paused = paused;
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::finish(RuntimeModel& model) noexcept {
    for (auto* stored : model.panes.items()) {
      const auto pane = asTerminal(stored); // NOLINT(misc-const-correctness): the pane's media is cancelled through its shared handle, a mutation tbc sees through the pane
      if (pane) {
        pane->body.media->cancel();
      }
    }

    for (auto media = model.retired_media; media; media = media->retiredNextMut()) {
      media->cancel();
    }

    for (;;) {
      worker_.wait([&](const Processor::Result& result) {
        pending_ = false;
        for (const auto& entry : std::span{result.entries}.first(result.count)) {
          entry.media->complete();
        }
      });

      Processor::Request request;

      enqueueRetired(model, request);
      for (auto* stored : model.panes.items()) {
        const auto pane = asTerminal(stored); // NOLINT(misc-const-correctness): the pane's media is sealed through its shared handle, a mutation tbc sees through the pane

        if (request.count == request.entries.size()) {
          break;
        }

        if (pane && pane->body.media->seal()) {
          request.entries.atMut(request.count++) = {.pane = pane->core.id, .generation = pane->core.generation, .media = pane->body.media};
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
    return std::ranges::any_of(clients.items(), [&](const ClientSession* client) {
      const auto* attachment = client == nullptr ? nullptr : client->attachment(pane);

      return attachment != nullptr && attachment->graphics.wantsImage(key, shared);
    });
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::enqueueRetired(tbc::mut_a<RuntimeModel> model, tbc::mut_a<Processor::Request> request) noexcept {
    auto* link = &model.retired_media;

    while (*link && request.count < request.entries.size()) {
      auto& media = **link;
      if (media.idle()) {
        auto next = std::move(media.retiredNextMut());

        *link = std::move(next);
        --model.retired_media_count;
        continue;
      }

      if (media.seal()) {
        request.entries.atMut(request.count++).media = *link;
      }

      link = &media.retiredNextMut();
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::apply(RuntimeModel& model, ClientStore& clients, Panes& service, const Processor::Result& result) {
    pending_ = false;
    for (const auto& entry : std::span{result.entries}.first(result.count)) {
      entry.media->complete();
      TELAR_DIAGNOSTIC(model.metrics.media.merge(entry.metrics));
    }

    for (const auto& entry : std::span{result.entries}.first(result.count)) {
      const auto pane = asTerminal(findPane(model.panes, {.id = entry.pane, .generation = entry.generation}));
      if (!pane) {
        continue;
      }

      if (entry.media->failed()) {
        service.failOutput(*pane);
        continue;
      }

      if (entry.reset) {
        requestGraphicsSnapshots(clients.items(), pane->core.id);
      }

      if (auto* terminal = pane->body.media->terminal()) {
        reportLimits(model.graphics_limits, *terminal);
        stageTransfers(clients, model.metrics, pane->core.id, terminal->graphics());
      }

      if (!pane->core.output_closed) {
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
      if (auto* attachment = client == nullptr ? nullptr : client->attachmentMut(pane)) {
        attachment->graphics.stageAtMediaBoundary(storage);
        TELAR_DIAGNOSTIC(metrics.graphics.merge(attachment->graphics.takeCounters()));
      }
    }
  }

  template <EventLoop Poller, typename Limits, HistoryEventSink History>
  void MediaService<Poller, Limits, History>::reportLimits(const GraphicsLimits& graphics, MediaTerminal& terminal) {
    auto& storage = terminal.graphicsMut();
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
