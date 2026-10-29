#pragma once

#include "../graphics/media_processor.hpp"
#include "../platform/observation_worker.hpp"
#include "pane_service.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, EventLoop Poller, typename Limits, HistoryEventSink History = DiscardedHistory>
class MediaService {
  using Processor = MediaProcessor<Memory>;

public:
  explicit MediaService(RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, Poller &poller, Limits &limits)
      : model_(model),
        panes_(panes),
        poller_(poller),
        limits_(limits),
        worker_(processor_) {}

  void start() {
    if (pending_) {
      return;
    }

    typename Processor::Request request;
    enqueueRetired(request);
    const auto panes = model_.panes.items();
    for (std::size_t visited = 0; visited < panes.size() && request.count < request.entries.size(); ++visited) {
      auto *pane = panes[next_slot_++ % panes.size()];
      if (pane == nullptr) {
        continue;
      }
      if (pane->media->failed()) {
        if (!pane->output_closed) {
          panes_.failOutput(*pane);
        }
        continue;
      }

      if (!pane->media->busy()) {
        pane->media->discardUnwantedTransfers([&](ImageKey key, bool shared) { return wanted(*pane, key, shared); });
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

  void collect() {
    if (pending_) {
      worker_.collect([&](const typename Processor::Result &result) { apply(result); });
    }
  }

  void updateReadInterest(Pane<Memory> &pane) {
    if (pane.output_closed) {
      return;
    }

    const bool paused = pane.terminal.hasPendingControl() || pane.media->holdsRead(Pane<Memory>::read_buffer_size);
    if (paused != pane.read_paused) {
      poller_.readInterest(pane.process->descriptor(), eventToken(EventSource::pane, pane.event_identity), !paused);
      pane.read_paused = paused;
    }
  }

  void finish() noexcept {
    for (auto *pane : model_.panes.items()) {
      if (pane != nullptr) {
        pane->media->cancel();
      }
    }
    for (auto media = model_.retired_media; media; media = media->retired_next) {
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
      enqueueRetired(request);
      for (auto *pane : model_.panes.items()) {
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

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

private:
  bool wanted(const Pane<Memory> &pane, ImageKey key, bool shared) const noexcept {
    for (const auto *client : model_.clients.items()) {
      const auto *attachment = client == nullptr ? nullptr : client->attachment(pane.id);
      if (attachment != nullptr && attachment->graphics.wantsImage(key, shared)) {
        return true;
      }
    }
    return false;
  }

  void enqueueRetired(typename Processor::Request &request) noexcept {
    auto *link = &model_.retired_media;
    while (*link && request.count < request.entries.size()) {
      auto &media = **link;
      if (media.idle()) {
        auto next = std::move(media.retired_next);
        *link = std::move(next);
        --model_.retired_media_count;
        continue;
      }

      if (media.seal()) {
        request.entries[request.count++].media = *link;
      }
      link = &media.retired_next;
    }
  }

  void apply(const typename Processor::Result &result) {
    pending_ = false;
    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      entry.media->complete();
      TELAR_DIAGNOSTIC(model_.metrics.media.merge(entry.metrics));
    }

    for (const auto &entry : std::span{result.entries}.first(result.count)) {
      auto *pane = model_.panes.find(entry.pane);
      if (pane == nullptr || pane->generation != entry.generation) {
        continue;
      }
      if (entry.media->failed()) {
        panes_.failOutput(*pane);
        continue;
      }

      if (entry.reset) {
        for (auto *client : model_.clients.items()) {
          if (auto *attachment = client == nullptr ? nullptr : client->attachment(pane->id)) {
            attachment->graphics.requestSnapshot();
          }
        }
      }

      if (auto *terminal = pane->media->terminal()) {
        reportLimits(*terminal);
        stageTransfers(*pane, terminal->graphics);

      }
      if (!pane->output_closed) {
        panes_.flushInput(*pane);
      }
      updateReadInterest(*pane);
    }
  }

  void stageTransfers(Pane<Memory> &pane, const GraphicsStorage<MediaAllocator<Memory>> &storage) {
    if (storage.revision() == 0) {
      return;
    }

    for (auto *client : model_.clients.items()) {
      if (auto *attachment = client == nullptr ? nullptr : client->attachment(pane.id)) {
        TELAR_DIAGNOSTIC(attachment->graphics.bindCounters(model_.metrics.graphics));
        attachment->graphics.stageAtMediaBoundary(storage);
      }
    }
  }

  void reportLimits(MediaTerminal<MediaAllocator<Memory>> &terminal) {
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
      limits_.report(LimitReach{.name = "graphics.max_image_bytes_per_screen", .noun = "bytes", .value = model_.graphics_limits.screenBytes()});
    }
  }

  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
  Poller &poller_;
  Limits &limits_;
  Processor processor_;
  ObservationWorker<Processor> worker_;
  std::size_t next_slot_ = 0;
  bool pending_ = false;
};

}
