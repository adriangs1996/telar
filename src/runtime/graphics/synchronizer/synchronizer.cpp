module;
#include "telar_platform/trace_macro.hpp"
#include <new>

#include "telar_base/diagnostics/config.hpp"

#include <fcntl.h>

module telar.runtime.graphics.synchronizer;

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

  template <ConcurrentAllocator Memory>
  auto MediaProcessor<Memory>::observe(tbc::view<const Request&, tbc::lt::a> request) noexcept -> tbc::view<Result, tbc::lt::a> {
    TELAR_TRACE("media.worker");
    auto result = request;

    for (auto& entry : std::span{result.entries}.first(result.count)) {
      entry.reset = entry.media->process();
      TELAR_DIAGNOSTIC(entry.metrics = entry.media->batchMetrics());
    }

    return result;
  }

  template <ConcurrentAllocator Memory>
  void MediaProcessor<Memory>::stop() noexcept {}

  template <Allocator Memory>
  GraphicsSynchronizer<Memory>::GraphicsSynchronizer(tbc::view<GraphicsCreditBudget&, tbc::lt::a> budget, std::uint64_t pane, tbc::view<std::shared_ptr<PaneMedia<Memory>>, tbc::lt::a> media)
      : media_(std::move(media)),
        credit_(budget),
        pane_(pane) {}

  template <Allocator Memory>
  GraphicsSynchronizer<Memory>::~GraphicsSynchronizer() {
    if (shared_) {
      media_->noteSharedTransport(false);
    }
  }

  template <Allocator Memory>
  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer<Memory>::synchronized(const GraphicsStorage<GraphicsMemory>& storage) const noexcept {
    return snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision();
  }

#if TELAR_DIAGNOSTICS
  template <Allocator Memory>
  std::size_t GraphicsSynchronizer<Memory>::transferBytes() const noexcept {
    return transfer_ ? transfer_->frozen.byteCount() : 0;
  }
#endif

  template <Allocator Memory>
  void GraphicsSynchronizer<Memory>::requestSnapshot() noexcept {
    transfer_.reset();
    known_images_.fill({});
    known_placements_.fill({});
    snapshot_ = SnapshotState::pending;
    observed_revision_ = 0;
  }

  template <Allocator Memory>
  void GraphicsSynchronizer<Memory>::configure(bool shared) noexcept {
    if (shared_ != shared) {
      shared_ = shared;
      media_->noteSharedTransport(shared);
      requestSnapshot();
    }
  }

  template <Allocator Memory>
  void GraphicsSynchronizer<Memory>::returnCredit(std::uint64_t bytes) noexcept {
    credit_.returnBytes(bytes);
  }

#if TELAR_DIAGNOSTICS
  template <Allocator Memory>
  diagnostics::GraphicsCounters GraphicsSynchronizer<Memory>::takeCounters() noexcept {
    return std::exchange(counters_, {});
  }
#endif

  template <Allocator Memory>
  bool GraphicsSynchronizer<Memory>::wantsImage(ImageKey key, bool shared) const noexcept {
    return shared_ == shared && !knows(key) && (!transfer_ || !sameImage(transfer_->image.key, key));
  }

  template <Allocator Memory>
  void GraphicsSynchronizer<Memory>::abandon(std::uint64_t revision) noexcept {
    transfer_.reset();
    snapshot_ = SnapshotState::idle;
    observed_revision_ = revision;
  }

  template <Allocator Memory>
  bool GraphicsSynchronizer<Memory>::advanceTransfer(Connection<Memory>& connection) {
    if (!transfer_) {
      TELAR_DIAGNOSTIC(if (snapshot_ != SnapshotState::idle || observed_revision_ != available_revision_) { diagnostics::accumulate(counters_.stage_deferred); });
      return false;
    }

    if (connection.queuedBytes() > maximum_queue_bytes) {
      return false;
    }

    return publishTransfer(connection, GraphicsHeader{.pane_id = pane_, .revision = transfer_->revision});
  }

  template <Allocator Memory>
  template <Allocator GraphicsMemory>
  bool GraphicsSynchronizer<Memory>::publish(Connection<Memory>& connection, const GraphicsStorage<GraphicsMemory>& storage) {
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
      send(connection, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::begin});
      snapshot_ = SnapshotState::open;
      return true;
    }

    if (transfer_ && publishTransfer(connection, header)) {
      return true;
    }

    for (auto& known : known_images_) {
      if (known.image_id == 0) {
        continue;
      }

      const auto current = std::ranges::find_if(storage.images(), [&](const auto& image) {
        return image.description.key.image_id == known.image_id;
      });
      if (current == storage.images().end() || (!sameImage(known, current->description.key) && knows(current->description.key))) {
        send(connection, GraphicsDeleteImage{.header = header, .key = known});
        for (auto& placement : known_placements_) {
          if (sameImage(placement.key, known)) {
            placement = {};
          }
        }

        known = {};
        return true;
      }
    }

    switch (stage(storage)) {
    case StageResult::staged:
      return publishTransfer(connection, header);
    case StageResult::blocked:
      return false;
    case StageResult::idle:
      break;
    }

    for (auto& known : known_placements_) {
      if (known.virtual_id == 0) {
        continue;
      }

      const auto current = std::ranges::find_if(storage.placements(), [&](const auto& placement) {
        return placement.virtual_id == known.virtual_id;
      });
      if (current == storage.placements().end()) {
        send(connection, GraphicsDeletePlacement{.header = header, .key = known.key, .virtual_id = known.virtual_id, .placement_id = known.placement_id});
        known = {};
        return true;
      }
    }

    for (const auto& placement : storage.placements()) {
      auto& known = placementSlot(placement.virtual_id);
      if (!samePlacement(known, placement)) {
        send(connection, GraphicsPlacementMessage{.header = header, .placement = placement});
        known = placement;
        return true;
      }
    }

    observed_revision_ = storage.revision();
    if (snapshot_ == SnapshotState::open) {
      send(connection, GraphicsSnapshot{.header = header, .phase = SnapshotPhase::end});
      snapshot_ = SnapshotState::idle;
    }

    return false;
  }

  template <Allocator Memory>
  template <Allocator GraphicsMemory>
  auto GraphicsSynchronizer<Memory>::stage(const GraphicsStorage<GraphicsMemory>& storage) -> StageResult {
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
        TELAR_DIAGNOSTIC(diagnostics::accumulate(pending_blocked_));
        return StageResult::blocked;
      }

      auto frozen = media_->takeTransfer(image.description.key, shared_);
      if (!frozen || !credit_.reserve(image.pixels.size())) {
        return StageResult::blocked;
      }

      Transfer transfer{.image = image.description, .revision = std::max<std::uint64_t>(1, storage.revision()), .frozen = std::move(*frozen)};

      for (const auto& placement : storage.placements()) {
        if (sameImage(placement.key, image.description.key)) {
          transfer.placements[transfer.placement_count++] = placement;
        }
      }

      transfer_ = std::move(transfer);
      TELAR_DIAGNOSTIC(diagnostics::accumulate(pending_adopted_));
      return StageResult::staged;
    }

    return StageResult::idle;
  }

  template <Allocator Memory>
  template <Allocator GraphicsMemory>
  void GraphicsSynchronizer<Memory>::stageAtMediaBoundary(const GraphicsStorage<GraphicsMemory>& storage) noexcept {
    TELAR_DIAGNOSTIC(available_revision_ = storage.revision());
    if (transfer_ || synchronized(storage)) {
      return;
    }

    try {
      if (stage(storage) == StageResult::staged) {
        TELAR_DIAGNOSTIC(diagnostics::accumulate(counters_.transfers_staged));
      }
    } catch (const std::bad_alloc&) {
      abandon(storage.revision());
    }
  }

  template <Allocator Memory>
  template <typename Message>
  void GraphicsSynchronizer<Memory>::send(Connection<Memory>& connection, const Message& message) {
    connection.send(message);
    TELAR_DIAGNOSTIC({
      counters_.record(message);
      diagnostics::accumulate(counters_.stage_blocked, std::exchange(pending_blocked_, 0));
      diagnostics::accumulate(counters_.transfers_adopted, std::exchange(pending_adopted_, 0));
    });
  }

  template <Allocator Memory>
  template <Allocator GraphicsMemory>
  void GraphicsSynchronizer<Memory>::initialize(const GraphicsStorage<GraphicsMemory>& storage) noexcept {
    TELAR_DIAGNOSTIC(available_revision_ = storage.revision());
    if (!initialized_) {
      initialized_ = true;
      if (!storage.images().empty()) {
        requestSnapshot();
      }
    }
  }

  template <Allocator Memory>
  bool GraphicsSynchronizer<Memory>::publishTransfer(Connection<Memory>& connection, GraphicsHeader header) {
    auto& transfer = *transfer_;

    header.revision = transfer.revision;
    if (!transfer.metadata_sent) {
      if (!transfer.frozen.name().empty()) {
        send(connection, GraphicsSharedImage{.header = header, .image = transfer.image, .name = transfer.frozen.name()});
        transfer.frozen.published();
      } else {
        send(connection, GraphicsImage{.header = header, .image = transfer.image});
      }

      transfer.metadata_sent = true;
      return true;
    }

    if (transfer.offset < transfer.frozen.pixels().size()) {
      const auto bytes = transfer.frozen.pixels().subspan(transfer.offset);
      const auto chunk = bytes.first(std::min(bytes.size(), maximum_chunk_bytes));

      send(connection, GraphicsImageChunk{.header = header, .key = transfer.image.key, .offset = transfer.offset, .bytes = chunk});
      transfer.offset += chunk.size();
      return true;
    }

    if (transfer.placement_index < transfer.placement_count) {
      const auto& placement = transfer.placements[transfer.placement_index];

      send(connection, GraphicsPlacementMessage{.header = header, .placement = placement});
      placementSlot(placement.virtual_id) = placement;
      ++transfer.placement_index;
      return true;
    }

    const auto empty = std::ranges::find_if(known_images_, [](ImageKey key) {
      return key.image_id == 0;
    });
    if (empty == known_images_.end()) {
      throw std::bad_alloc{};
    }

    *empty = transfer.image.key;
    transfer_.reset();
    return false;
  }

  template <Allocator Memory>
  bool GraphicsSynchronizer<Memory>::knows(ImageKey key) const noexcept {
    return std::ranges::any_of(known_images_, [&](ImageKey known) {
      return sameImage(known, key);
    });
  }

  template <Allocator Memory>
  GraphicsPlacement& GraphicsSynchronizer<Memory>::placementSlot(std::uint64_t identity) {
    auto existing = std::ranges::find_if(known_placements_, [&](const auto& placement) {
      return placement.virtual_id == identity;
    });
    if (existing != known_placements_.end()) {
      return *existing;
    }

    auto empty = std::ranges::find_if(known_placements_, [](const auto& placement) {
      return placement.virtual_id == 0;
    });
    if (empty == known_placements_.end()) {
      throw std::bad_alloc{};
    }

    return *empty;
  }

  template class MediaProcessor<telar::ConcurrentMemory>;

  template class GraphicsSynchronizer<telar::ConcurrentMemory>;
  template bool GraphicsSynchronizer<telar::ConcurrentMemory>::synchronized<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) const noexcept;
  template bool GraphicsSynchronizer<telar::ConcurrentMemory>::publish<telar::ConcurrentMemory>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::ConcurrentMemory>& storage);
  template GraphicsSynchronizer<telar::ConcurrentMemory>::StageResult GraphicsSynchronizer<telar::ConcurrentMemory>::stage<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage);
  template void GraphicsSynchronizer<telar::ConcurrentMemory>::stageAtMediaBoundary<telar::ConcurrentMemory>(const GraphicsStorage<telar::ConcurrentMemory>& storage) noexcept;
  template bool GraphicsSynchronizer<telar::ConcurrentMemory>::synchronized<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) const noexcept;
  template bool GraphicsSynchronizer<telar::ConcurrentMemory>::publish<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(Connection<telar::ConcurrentMemory>& connection, const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
  template GraphicsSynchronizer<telar::ConcurrentMemory>::StageResult GraphicsSynchronizer<telar::ConcurrentMemory>::stage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage);
  template void GraphicsSynchronizer<telar::ConcurrentMemory>::stageAtMediaBoundary<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>(const GraphicsStorage<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>& storage) noexcept;

}
