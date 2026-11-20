module;
#include "telar_platform/trace_macro.hpp"

#include "telar_base/diagnostics/config.hpp"

module telar.runtime.graphics.synchronizer;

import telar.runtime.diagnostics.line;
import telar.wire.graphics;

namespace telar::runtime {

  bool GraphicsCreditBudget::acquire(std::size_t bytes) noexcept {
    if (bytes > available()) {
      return false;
    }

    used_ += bytes;
    return true;
  }

  void GraphicsCreditBudget::release(std::size_t bytes) noexcept {
    used_ -= bytes;
  }

  std::size_t GraphicsCreditBudget::used() const noexcept {
    return used_;
  }

  std::size_t GraphicsCreditBudget::available() const noexcept {
    return limit - used_;
  }

  GraphicsCreditLedger::GraphicsCreditLedger(GraphicsCreditBudget& budget) noexcept
      : budget_(budget) {}

  GraphicsCreditLedger::~GraphicsCreditLedger() {
    budget_.release(graphics_credit_bytes - available_);
  }

  bool GraphicsCreditLedger::canReserve(std::size_t bytes) const noexcept {
    return bytes <= available_ && bytes <= budget_.available();
  }

  bool GraphicsCreditLedger::reserve(std::size_t bytes) noexcept {
    if (bytes > available_ || !budget_.acquire(bytes)) {
      return false;
    }

    available_ -= bytes;
    return true;
  }

  bool GraphicsCreditLedger::returnBytes(std::uint64_t bytes) noexcept {
    if (bytes == 0 || bytes > graphics_credit_bytes - available_) {
      return false;
    }

    available_ += bytes;
    budget_.release(bytes);
    return true;
  }

  std::size_t GraphicsCreditLedger::available() const noexcept {
    return available_;
  }

  auto MediaProcessor::observe(tbc::ref_a<Request> request) noexcept -> tbc::val_a<Result> {
    TELAR_TRACE("media.worker");
    auto result = request;

    for (auto& entry : result.entries.viewMut().first(result.count)) {
      entry.reset = entry.media->process();
      TELAR_DIAGNOSTIC(entry.metrics = entry.media->batchMetrics());
    }

    return result;
  }

  void MediaProcessor::stop() noexcept {}

  GraphicsSynchronizer::GraphicsSynchronizer(tbc::mut_a<GraphicsCreditBudget> budget, std::uint64_t pane, tbc::val_a<std::shared_ptr<PaneMedia>> media)
      : media_(std::move(media)),
        credit_(budget),
        pane_(pane) {}

  GraphicsSynchronizer::~GraphicsSynchronizer() {
    if (shared_) {
      media_->noteSharedTransport(false);
    }
  }

  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer::synchronized(const GraphicsStorage<GraphicsMemory>& storage) const noexcept {
    return snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision();
  }

#if TELAR_DIAGNOSTICS
  std::size_t GraphicsSynchronizer::transferBytes() const noexcept {
    return transfer_ ? transfer_->frozen.byteCount() : 0;
  }
#endif

  void GraphicsSynchronizer::requestSnapshot() noexcept {
    transfer_.reset();
    known_images_.fill({});
    known_placements_.fill({});
    snapshot_ = SnapshotState::pending;
    observed_revision_ = 0;
  }

  void GraphicsSynchronizer::configure(bool shared) noexcept {
    if (shared_ != shared) {
      shared_ = shared;
      media_->noteSharedTransport(shared);
      requestSnapshot();
    }
  }

  void GraphicsSynchronizer::returnCredit(std::uint64_t bytes) noexcept {
    credit_.returnBytes(bytes);
  }

#if TELAR_DIAGNOSTICS
  diagnostics::GraphicsCounters GraphicsSynchronizer::takeCounters() noexcept {
    return std::exchange(metrics_.counters, {});
  }
#endif

  bool GraphicsSynchronizer::wantsImage(ImageKey key, bool shared) const noexcept {
    return shared_ == shared && !knows(key) && (!transfer_ || !sameImage(transfer_->image.key, key));
  }

  void GraphicsSynchronizer::abandon(std::uint64_t revision) noexcept {
    transfer_.reset();
    snapshot_ = SnapshotState::idle;
    observed_revision_ = revision;
  }

  bool GraphicsSynchronizer::advanceTransfer(Connection<ConcurrentMemory>& connection) {
    if (!transfer_) {
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.counters.stage_deferred, static_cast<std::uint64_t>(snapshot_ != SnapshotState::idle || observed_revision_ != metrics_.available_revision)));
      return false;
    }

    if (connection.queuedBytes() > maximum_queue_bytes) {
      return false;
    }

    return publishTransfer(connection, GraphicsHeader{.pane_id = pane_, .revision = transfer_->revision});
  }

  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer::publish(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage) {
    TELAR_TRACE("graphics.publish");
    if (connection.queuedBytes() > maximum_queue_bytes) {
      return false;
    }

    initialize(storage);

    if (snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision()) {
      return false;
    }

    const GraphicsHeader header{.pane_id = pane_, .revision = std::max<std::uint64_t>(1, storage.revision())};

    if (snapshot_ == SnapshotState::pending) {
      send(connection, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::begin}, metrics_);
      snapshot_ = SnapshotState::open;
      return true;
    }

    if ((transfer_ && publishTransfer(connection, header)) || deleteStaleImage(connection, storage, header)) {
      return true;
    }

    switch (stage(storage)) {
    case StageResult::staged:
      return publishTransfer(connection, header);
    case StageResult::blocked:
      return false;
    case StageResult::idle:
      break;
    }

    if (deleteStalePlacement(connection, storage, header) || sendChangedPlacement(connection, storage, header)) {
      return true;
    }

    observed_revision_ = storage.revision();
    if (snapshot_ == SnapshotState::open) {
      send(connection, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::end}, metrics_);
      snapshot_ = SnapshotState::idle;
    }

    return false;
  }

  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer::deleteStaleImage(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header) {
    for (auto& known : known_images_.viewMut()) {
      if (known.image_id == 0) {
        continue;
      }

      const auto current = std::ranges::find_if(storage.images(), [&](const auto& image) {
        return image.description.key.image_id == known.image_id;
      });
      if (current == storage.images().end() || (!sameImage(known, current->description.key) && knows(current->description.key))) {
        const auto of_known = [&known](const GraphicsPlacement& placement) {
          return sameImage(placement.key, known);
        };

        send(connection, GraphicsDeleteImage{.header = header, .key = known}, metrics_);
        std::ranges::replace_if(known_placements_.viewMut(), of_known, GraphicsPlacement{});
        known = {};
        return true;
      }
    }

    return false;
  }

  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer::deleteStalePlacement(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header) {
    for (auto& known : known_placements_.viewMut()) {
      if (known.virtual_id == 0) {
        continue;
      }

      const auto current = std::ranges::find_if(storage.placements(), [&](const auto& placement) {
        return placement.virtual_id == known.virtual_id;
      });
      if (current == storage.placements().end()) {
        send(connection, GraphicsDeletePlacement{.header = header, .key = known.key, .virtual_id = known.virtual_id, .placement_id = known.placement_id}, metrics_);
        known = {};
        return true;
      }
    }

    return false;
  }

  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer::sendChangedPlacement(Connection<ConcurrentMemory>& connection, const GraphicsStorage<GraphicsMemory>& storage, GraphicsHeader header) {
    for (const auto& placement : storage.placements()) {
      auto& known = placementSlot(known_placements_.viewMut(), placement.virtual_id);
      if (!samePlacement(known, placement)) {
        send(connection, GraphicsPlacementMessage{.header = header, .placement = placement}, metrics_);
        known = placement;
        return true;
      }
    }

    return false;
  }

  template <Allocator GraphicsMemory>
  auto GraphicsSynchronizer::stage(const GraphicsStorage<GraphicsMemory>& storage) -> StageResult {
    TELAR_TRACE("graphics.stage");
    initialize(storage);
    if (transfer_) {
      return StageResult::staged;
    }

    if (snapshot_ == SnapshotState::pending) {
      return StageResult::idle;
    }

    for (const auto& image : storage.images()) {
      if (knows(image.description.key)) {
        continue;
      }

      if (!credit_.canReserve(image.pixels.size())) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.pending_blocked));
        return StageResult::blocked;
      }

      auto frozen = media_->takeTransfer(image.description.key, shared_);
      if (!frozen || !credit_.reserve(image.pixels.size())) {
        return StageResult::blocked;
      }

      Transfer transfer{.image = image.description, .revision = std::max<std::uint64_t>(1, storage.revision()), .frozen = std::move(frozen.getMut())};

      for (const auto& placement : storage.placements()) {
        if (sameImage(placement.key, image.description.key)) {
          transfer.placements.atMut(transfer.placement_count++) = placement;
        }
      }

      transfer_ = std::move(transfer);
      TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.pending_adopted));
      return StageResult::staged;
    }

    return StageResult::idle;
  }

  template <Allocator GraphicsMemory>
  void GraphicsSynchronizer::stageAtMediaBoundary(const GraphicsStorage<GraphicsMemory>& storage) noexcept {
    TELAR_DIAGNOSTIC(metrics_.available_revision = storage.revision());
    if (transfer_ || synchronized(storage)) {
      return;
    }

    try {
      if (stage(storage) == StageResult::staged) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics_.counters.transfers_staged));
      }
    } catch (const std::bad_alloc&) {
      abandon(storage.revision());
    }
  }

  template <typename Message>
  void GraphicsSynchronizer::send(Connection<ConcurrentMemory>& connection, const Message& message, [[maybe_unused]] Metrics& metrics) {
    connection.send(message);
    TELAR_DIAGNOSTIC(metrics.counters.record(message));
    TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics.counters.stage_blocked, std::exchange(metrics.pending_blocked, 0)));
    TELAR_DIAGNOSTIC(diagnostics::accumulate(metrics.counters.transfers_adopted, std::exchange(metrics.pending_adopted, 0)));
  }

  template <Allocator GraphicsMemory>
  void GraphicsSynchronizer::initialize(const GraphicsStorage<GraphicsMemory>& storage) noexcept {
    TELAR_DIAGNOSTIC(metrics_.available_revision = storage.revision());
    if (!initialized_) {
      initialized_ = true;
      if (!storage.images().empty()) {
        requestSnapshot();
      }
    }
  }

  bool GraphicsSynchronizer::publishTransfer(Connection<ConcurrentMemory>& connection, GraphicsHeader header) {
    auto& transfer = transfer_.getMut();

    header.revision = transfer.revision;
    if (!transfer.metadata_sent) {
      if (!transfer.frozen.name().empty()) {
        send(connection, GraphicsSharedImage{.header = header, .image = transfer.image, .name = transfer.frozen.name()}, metrics_);
        transfer.frozen.published();
      } else {
        send(connection, GraphicsImage{.header = header, .image = transfer.image}, metrics_);
      }

      transfer.metadata_sent = true;
      return true;
    }

    if (transfer.offset < transfer.frozen.pixels().size()) {
      const auto bytes = transfer.frozen.pixels().subspan(transfer.offset);
      const auto chunk = bytes.first(std::min(bytes.size(), maximum_chunk_bytes));

      send(connection, GraphicsImageChunk{.header = header, .key = transfer.image.key, .offset = transfer.offset, .bytes = chunk}, metrics_);
      transfer.offset += chunk.size();
      return true;
    }

    if (transfer.placement_index < transfer.placement_count) {
      const auto& placement = transfer.placements[transfer.placement_index];

      send(connection, GraphicsPlacementMessage{.header = header, .placement = placement}, metrics_);
      placementSlot(known_placements_.viewMut(), placement.virtual_id) = placement;
      ++transfer.placement_index;
      return true;
    }

    const auto images = known_images_.viewMut();
    const auto empty = std::ranges::find_if(images, [](ImageKey key) {
      return key.image_id == 0;
    });
    if (empty == images.end()) {
      throw std::bad_alloc{};
    }

    *empty = transfer.image.key;
    transfer_.reset();
    return false;
  }

  bool GraphicsSynchronizer::knows(ImageKey key) const noexcept {
    return std::ranges::any_of(known_images_, [&](ImageKey known) {
      return sameImage(known, key);
    });
  }

  GraphicsPlacement& GraphicsSynchronizer::placementSlot(std::span<GraphicsPlacement> placements, std::uint64_t identity) {
    for (auto& placement : placements) {
      if (placement.virtual_id == identity) {
        return placement;
      }
    }

    for (auto& placement : placements) {
      if (placement.virtual_id == 0) {
        return placement;
      }
    }

    throw std::bad_alloc{};
  }

  template bool GraphicsSynchronizer::synchronized<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) const noexcept;
  template bool GraphicsSynchronizer::publish<telar::ConcurrentMemory>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::ConcurrentMemory>& storage);
  template GraphicsSynchronizer::StageResult GraphicsSynchronizer::stage<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage);
  template void GraphicsSynchronizer::stageAtMediaBoundary<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) noexcept;
  template bool GraphicsSynchronizer::synchronized<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) const noexcept;
  template bool GraphicsSynchronizer::publish<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
  template GraphicsSynchronizer::StageResult GraphicsSynchronizer::stage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
  template void GraphicsSynchronizer::stageAtMediaBoundary<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) noexcept;

}
