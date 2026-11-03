#pragma once

#include "../diagnostics/graphics_counters.hpp"
#include "../diagnostics/trace.hpp"
#include "../transport/connection.hpp"
#include "credit.hpp"
#include "pane_media.hpp"
#include "telar_base/diagnostics/config.hpp"

namespace telar::runtime {

template <Allocator Memory>
class GraphicsSynchronizer {
public:
  enum class StageResult {
    idle,
    blocked,
    staged
  };

  explicit GraphicsSynchronizer(GraphicsCreditBudget &budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media)
      : media_(std::move(media)),
        credit_(budget),
        pane_(pane) {}

  ~GraphicsSynchronizer() {
    if (shared_) {
      media_->noteSharedTransport(false);
    }
  }

  template <Allocator GraphicsMemory>
  bool synchronized(const GraphicsStorage<GraphicsMemory> &storage) const noexcept {
    return snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision();
  }

#if TELAR_DIAGNOSTICS
  std::size_t transferBytes() const noexcept {
    return transfer_ ? transfer_->frozen.byteCount() : 0;
  }
#endif

  void requestSnapshot() noexcept {
    transfer_.reset();
    known_images_.fill({});
    known_placements_.fill({});
    snapshot_ = SnapshotState::pending;
    observed_revision_ = 0;
  }

  void configure(bool shared) noexcept {
    if (shared_ != shared) {
      shared_ = shared;
      media_->noteSharedTransport(shared);
      requestSnapshot();
    }
  }

  void returnCredit(std::uint64_t bytes) noexcept {
    credit_.returnBytes(bytes);
  }

#if TELAR_DIAGNOSTICS
  void bindCounters(diagnostics::GraphicsCounters &counters) noexcept {
    counters_ = &counters;
  }
#endif

  bool wantsImage(ImageKey key, bool shared) const noexcept {
    return shared_ == shared && !knows(key) && (!transfer_ || !sameImage(transfer_->image.key, key));
  }

  void abandon(std::uint64_t revision) noexcept {
    transfer_.reset();
    snapshot_ = SnapshotState::idle;
    observed_revision_ = revision;
  }

  bool advanceTransfer(Connection<Memory> &connection) {
    if (!transfer_) {
      TELAR_DIAGNOSTIC(if (counters_ != nullptr && (snapshot_ != SnapshotState::idle || observed_revision_ != available_revision_)) { diagnostics::accumulate(counters_->stage_deferred); });
      return false;
    }

    if (connection.queuedBytes() > maximum_queue_bytes) {
      return false;
    }

    return publishTransfer(connection, GraphicsHeader{.pane_id = pane_, .revision = transfer_->revision});
  }

  template <Allocator GraphicsMemory>
  bool publish(Connection<Memory> &connection, const GraphicsStorage<GraphicsMemory> &storage) {
    TELAR_TRACE("graphics.publish");
    if (connection.queuedBytes() > maximum_queue_bytes) {
      return false;
    }
    initialize(storage);

    if (snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision()) {
      return false;
    }
    const GraphicsHeader header{.pane_id = pane_,
                                .revision = std::max<std::uint64_t>(1, storage.revision())};
    if (snapshot_ == SnapshotState::pending) {
      send(connection, GraphicsSnapshot{.header = header,
                                        .phase = SnapshotPhase::begin});
      snapshot_ = SnapshotState::open;
      return true;
    }
    if (transfer_ && publishTransfer(connection, header)) {
      return true;
    }

    for (auto &known : known_images_) {
      if (known.image_id == 0) {
        continue;
      }
      const auto current = std::ranges::find_if(storage.images(), [&](const auto &image) { return image.description.key.image_id == known.image_id; });
      if (current == storage.images().end() || (!sameImage(known, current->description.key) && knows(current->description.key))) {
        send(connection, GraphicsDeleteImage{.header = header,
                                             .key = known});
        for (auto &placement : known_placements_) {
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

    for (auto &known : known_placements_) {
      if (known.virtual_id == 0) {
        continue;
      }
      const auto current = std::ranges::find_if(storage.placements(), [&](const auto &placement) { return placement.virtual_id == known.virtual_id; });
      if (current == storage.placements().end()) {
        send(connection, GraphicsDeletePlacement{.header = header,
                                                 .key = known.key,
                                                 .virtual_id = known.virtual_id,
                                                 .placement_id = known.placement_id});
        known = {};
        return true;
      }
    }
    for (const auto &placement : storage.placements()) {
      auto &known = placementSlot(placement.virtual_id);
      if (!samePlacement(known, placement)) {
        send(connection, GraphicsPlacementMessage{.header = header,
                                                  .placement = placement});
        known = placement;
        return true;
      }
    }
    observed_revision_ = storage.revision();
    if (snapshot_ == SnapshotState::open) {
      send(connection, GraphicsSnapshot{.header = header,
                                        .phase = SnapshotPhase::end});
      snapshot_ = SnapshotState::idle;
    }
    return false;
  }

  template <Allocator GraphicsMemory>
  StageResult stage(const GraphicsStorage<GraphicsMemory> &storage) {
    TELAR_TRACE("graphics.stage");
    initialize(storage);
    if (transfer_) {
      return StageResult::staged;
    }

    if (snapshot_ == SnapshotState::pending) {
      return StageResult::idle;
    }

    for (const auto &image : storage.images()) {
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

      Transfer transfer{.image = image.description,
                        .revision = std::max<std::uint64_t>(1, storage.revision()),
                        .frozen = std::move(*frozen)};
      for (const auto &placement : storage.placements()) {
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

  template <Allocator GraphicsMemory>
  void stageAtMediaBoundary(const GraphicsStorage<GraphicsMemory> &storage) noexcept {
    TELAR_DIAGNOSTIC(available_revision_ = storage.revision());
    if (transfer_ || synchronized(storage)) {
      return;
    }

    try {
      if (stage(storage) == StageResult::staged) {
        TELAR_DIAGNOSTIC(if (counters_ != nullptr) { diagnostics::accumulate(counters_->transfers_staged); });
      }
    } catch (const std::bad_alloc &) {
      abandon(storage.revision());
    }
  }

private:
  template <typename Message>
  void send(Connection<Memory> &connection, const Message &message) {
    connection.send(message);
    TELAR_DIAGNOSTIC(if (counters_ != nullptr) {
      counters_->record(message);
      diagnostics::accumulate(counters_->stage_blocked, std::exchange(pending_blocked_, 0));
      diagnostics::accumulate(counters_->transfers_adopted, std::exchange(pending_adopted_, 0));
    });
  }

  template <Allocator GraphicsMemory>
  void initialize(const GraphicsStorage<GraphicsMemory> &storage) noexcept {
    TELAR_DIAGNOSTIC(available_revision_ = storage.revision());
    if (!initialized_) {
      initialized_ = true;
      if (!storage.images().empty()) {
        requestSnapshot();
      }
    }
  }

  enum class SnapshotState {
    idle,
    pending,
    open
  };

  struct Transfer {
    ImageDescription image;
    std::uint64_t revision;
    FrozenImage<Memory> frozen;
    std::size_t offset = 0;
    std::array<GraphicsPlacement, graphics_placement_count> placements{};
    std::size_t placement_count = 0;
    std::size_t placement_index = 0;
    bool metadata_sent = false;
  };

  bool publishTransfer(Connection<Memory> &connection, GraphicsHeader header) {
    auto &transfer = *transfer_;
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
      send(connection, GraphicsImageChunk{.header = header,
                                          .key = transfer.image.key,
                                          .offset = transfer.offset,
                                          .bytes = chunk});
      transfer.offset += chunk.size();
      return true;
    }
    if (transfer.placement_index < transfer.placement_count) {
      const auto &placement = transfer.placements[transfer.placement_index];
      send(connection, GraphicsPlacementMessage{.header = header,
                                                .placement = placement});
      placementSlot(placement.virtual_id) = placement;
      ++transfer.placement_index;
      return true;
    }
    const auto empty = std::ranges::find_if(known_images_, [](ImageKey key) { return key.image_id == 0; });
    if (empty == known_images_.end()) {
      throw std::bad_alloc{};
    }
    *empty = transfer.image.key;
    transfer_.reset();
    return false;
  }

  bool knows(ImageKey key) const noexcept {
    return std::ranges::any_of(known_images_, [&](ImageKey known) { return sameImage(known, key); });
  }

  GraphicsPlacement &placementSlot(std::uint64_t identity) {
    auto existing = std::ranges::find_if(known_placements_, [&](const auto &placement) { return placement.virtual_id == identity; });
    if (existing != known_placements_.end()) {
      return *existing;
    }
    auto empty = std::ranges::find_if(known_placements_, [](const auto &placement) { return placement.virtual_id == 0; });
    if (empty == known_placements_.end()) {
      throw std::bad_alloc{};
    }
    return *empty;
  }

  static constexpr std::size_t maximum_chunk_bytes = 1024 * 1024;
  static constexpr std::size_t maximum_queue_bytes = 2 * 1024 * 1024;
  // Frozen transfers borrow this pane's allocator until their destruction.
  std::shared_ptr<PaneMedia<Memory>> media_;
  GraphicsCreditLedger credit_;
  std::uint64_t pane_;
  std::optional<Transfer> transfer_;
  std::array<ImageKey, graphics_image_count * 2> known_images_{};
  std::array<GraphicsPlacement, graphics_placement_count * 2> known_placements_{};
  std::uint64_t observed_revision_ = 0;
  SnapshotState snapshot_ = SnapshotState::idle;
  bool shared_ = false;
  bool initialized_ = false;
#if TELAR_DIAGNOSTICS
  diagnostics::GraphicsCounters *counters_ = nullptr;
  std::uint64_t available_revision_ = 0;
  std::uint64_t pending_blocked_ = 0;
  std::uint64_t pending_adopted_ = 0;
#endif
};

}
