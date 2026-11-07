module;
#include "telar_platform/trace_macro.hpp"
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <ghostty/vt.h>
#include <source_location>
#include <type_traits>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>
#include <stdlib.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include <array>

#include <cstring>
#include <variant>
#include <cstddef>
#include <span>
#include <utility>
#include <stdexcept>
#include <charconv>
#include <limits>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>

#include <concepts>
#include <cassert>
#include <bit>
#include <exception>
#include <cerrno>
#include <chrono>

export module telar.runtime.graphics.synchronizer;

export import telar.runtime.graphics.prepared_images;


export import telar.runtime.graphics.pane_media;


export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.transport.connection;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: graphics/credit.cppm
export {
namespace telar::runtime {

class GraphicsCreditBudget {
public:
  inline bool acquire(std::size_t bytes) noexcept {
    if (bytes > available()) {
      return false;
    }
    used_ += bytes;
    return true;
  }

  inline void release(std::size_t bytes) noexcept {
    used_ -= bytes;
  }

  inline std::size_t used() const noexcept {
    return used_;
  }

  inline std::size_t available() const noexcept {
    return limit - used_;
  }

  static constexpr std::size_t limit = 512 * 1024 * 1024;

private:
  std::size_t used_ = 0;
};

class GraphicsCreditLedger {
public:
  inline explicit GraphicsCreditLedger(GraphicsCreditBudget &budget) noexcept
      : budget_(budget) {}

  inline ~GraphicsCreditLedger() {
    budget_.release(graphics_credit_bytes - available_);
  }

  GraphicsCreditLedger(const GraphicsCreditLedger &) = delete;
  GraphicsCreditLedger &operator=(const GraphicsCreditLedger &) = delete;

  inline bool canReserve(std::size_t bytes) const noexcept {
    return bytes <= available_ && bytes <= budget_.available();
  }

  inline bool reserve(std::size_t bytes) noexcept {
    if (bytes > available_ || !budget_.acquire(bytes)) {
      return false;
    }
    available_ -= bytes;
    return true;
  }

  inline bool returnBytes(std::uint64_t bytes) noexcept {
    if (bytes == 0 || bytes > graphics_credit_bytes - available_) {
      return false;
    }
    available_ += bytes;
    budget_.release(bytes);
    return true;
  }

  inline std::size_t available() const noexcept {
    return available_;
  }

private:
  GraphicsCreditBudget &budget_;
  std::size_t available_ = graphics_credit_bytes;
};

}
}

// Interface: graphics/media_processor.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class MediaProcessor {
public:
  struct Entry {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    std::shared_ptr<PaneMedia<Memory>> media;
    bool reset = false;
#if TELAR_DIAGNOSTICS
    diagnostics::MediaCounters metrics{};
#endif
  };

  struct Request {
    std::array<Entry, 8> entries;
    std::size_t count = 0;
  };

  using Result = Request;

  inline Result observe(const Request &request) noexcept {
    TELAR_TRACE("media.worker");
    auto result = request;
    for (auto &entry : std::span{result.entries}.first(result.count)) {
      entry.reset = entry.media->process();
      TELAR_DIAGNOSTIC(entry.metrics = entry.media->batchMetrics());
    }
    return result;
  }

  inline void stop() noexcept {}
};

}
}

// Interface: graphics/synchronizer.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class GraphicsSynchronizer {
public:
  enum class StageResult {
    idle,
    blocked,
    staged
  };

  inline explicit GraphicsSynchronizer(GraphicsCreditBudget &budget, std::uint64_t pane, std::shared_ptr<PaneMedia<Memory>> media)
      : media_(std::move(media)),
        credit_(budget),
        pane_(pane) {}

  inline ~GraphicsSynchronizer() {
    if (shared_) {
      media_->noteSharedTransport(false);
    }
  }

  template <Allocator GraphicsMemory>
  inline bool synchronized(const GraphicsStorage<GraphicsMemory> &storage) const noexcept {
    return snapshot_ == SnapshotState::idle && !transfer_ && observed_revision_ == storage.revision();
  }

#if TELAR_DIAGNOSTICS
  inline std::size_t transferBytes() const noexcept {
    return transfer_ ? transfer_->frozen.byteCount() : 0;
  }
#endif

  inline void requestSnapshot() noexcept {
    transfer_.reset();
    known_images_.fill({});
    known_placements_.fill({});
    snapshot_ = SnapshotState::pending;
    observed_revision_ = 0;
  }

  inline void configure(bool shared) noexcept {
    if (shared_ != shared) {
      shared_ = shared;
      media_->noteSharedTransport(shared);
      requestSnapshot();
    }
  }

  inline void returnCredit(std::uint64_t bytes) noexcept {
    credit_.returnBytes(bytes);
  }

#if TELAR_DIAGNOSTICS
  inline void bindCounters(diagnostics::GraphicsCounters &counters) noexcept {
    counters_ = &counters;
  }
#endif

  inline bool wantsImage(ImageKey key, bool shared) const noexcept {
    return shared_ == shared && !knows(key) && (!transfer_ || !sameImage(transfer_->image.key, key));
  }

  inline void abandon(std::uint64_t revision) noexcept {
    transfer_.reset();
    snapshot_ = SnapshotState::idle;
    observed_revision_ = revision;
  }

  inline bool advanceTransfer(Connection<Memory> &connection) {
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
  inline bool publish(Connection<Memory> &connection, const GraphicsStorage<GraphicsMemory> &storage) {
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
  inline StageResult stage(const GraphicsStorage<GraphicsMemory> &storage) {
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
  inline void stageAtMediaBoundary(const GraphicsStorage<GraphicsMemory> &storage) noexcept {
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
  inline void send(Connection<Memory> &connection, const Message &message) {
    connection.send(message);
    TELAR_DIAGNOSTIC(if (counters_ != nullptr) {
      counters_->record(message);
      diagnostics::accumulate(counters_->stage_blocked, std::exchange(pending_blocked_, 0));
      diagnostics::accumulate(counters_->transfers_adopted, std::exchange(pending_adopted_, 0));
    });
  }

  template <Allocator GraphicsMemory>
  inline void initialize(const GraphicsStorage<GraphicsMemory> &storage) noexcept {
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

  inline bool publishTransfer(Connection<Memory> &connection, GraphicsHeader header) {
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

  inline bool knows(ImageKey key) const noexcept {
    return std::ranges::any_of(known_images_, [&](ImageKey known) { return sameImage(known, key); });
  }

  inline GraphicsPlacement &placementSlot(std::uint64_t identity) {
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
}
