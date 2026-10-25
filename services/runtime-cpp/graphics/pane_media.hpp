#pragma once

#include "../diagnostics/config.hpp"
#include "../diagnostics/media_counters.hpp"
#include "../diagnostics/media_queue.hpp"
#include "kitty_framing.hpp"
#include "media_batch.hpp"
#include "media_budget.hpp"
#include "media_input.hpp"
#include "media_terminal.hpp"
#include "prepared_images.hpp"
#include "transfer_requests.hpp"
#include <atomic>

namespace telar::runtime {

template <Allocator Memory>
class PaneMedia {
public:
  using AllocatedMemory = MediaAllocator<Memory>;

  explicit PaneMedia(Memory &memory, MediaBudget &budget, GraphicsLimits limits, TerminalSize size, std::shared_ptr<PtyResponseQueue> responses = {})
      : memory_(memory, budget, limits.pane_bytes),
        prepared_(memory, memory_),
        requests_(memory, memory_),
        responses_(responses ? std::move(responses) : std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})),
        limits_(limits),
        current_size_(size) {
    terminal_.emplace(memory_, size, limits, responses_);
  }

  void output(std::span<const Byte> bytes) noexcept {
    const bool kitty = framing_.touches(bytes);
    auto &batch = batches_[active_];
    if (!batch.append(bytes)) {
      dropActive(bytes.size());
      batch.append(bytes);
    }
    batch.kitty |= kitty;
    TELAR_DIAGNOSTIC(observeQueue());
  }

  void resize(TerminalSize size) noexcept {
    current_size_ = size;
    auto &batch = batches_[active_];
    if (!batch.resize(size)) {
      dropActive(0);
      batch.resize(size);
    }
    TELAR_DIAGNOSTIC(observeQueue());
  }

  bool holdsRead(std::size_t bytes) const noexcept {
    return busy_ && !batches_[active_].hasReadCapacity(bytes) && (batches_[active_].kitty || batches_[sealed_].kitty || framing_.inside());
  }

  bool seal() noexcept {
    if (busy_ || batches_[active_].events().empty()) {
      return false;
    }

    sealed_ = active_;
    active_ ^= 1;
    sealed_size_ = current_size_;
    busy_ = true;
    return true;
  }

  void complete() noexcept {
    batches_[sealed_].clear();
    busy_ = false;
    TELAR_DIAGNOSTIC(observeQueue());
  }

  bool process() noexcept {
    TELAR_TRACE("media.process");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::media});
    TELAR_DIAGNOSTIC(batch_metrics_ = {});
    TELAR_DIAGNOSTIC(diagnostics::TimedScope timing{batch_metrics_.ingest});
    const auto &batch = batches_[sealed_];
    TELAR_DIAGNOSTIC(batch_metrics_.bytes = batch.byteCount());
    bool reset = batch.reset_before || !terminal_;
    try {
      if (reset) {
        prepared_.clear();
        requests_.clear();
        terminal_.reset();
        terminal_.emplace(memory_, sealed_size_, limits_, responses_);
      }

      MediaInput input{memory_, *terminal_, prepared_, shared_clients_};
      for (const auto &event : batch.events()) {
        if (const auto *output = std::get_if<MediaBatch::Output>(&event)) {
          [[maybe_unused]] const auto statistics = input.feed(batch.bytes(*output), scratch_);
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.discarded_frames, statistics.discarded));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.unavailable_frames, statistics.unavailable));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.forwarded_frames, statistics.forwarded));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.direct_frames, statistics.direct));
          TELAR_DIAGNOSTIC(diagnostics::accumulate(batch_metrics_.file_frames, statistics.file));
        } else {
          terminal_->resize(std::get<TerminalSize>(event));
        }
      }
      terminal_->refresh();
      if (shared_clients_.load(std::memory_order_acquire) != 0) {
        prepared_.prepare(terminal_->graphics.images());
      }
      requests_.process(terminal_->graphics.images());
    } catch (...) {
      prepared_.clear();
      requests_.clear();
      terminal_.reset();
      reset = true;
      ++failures_;
      TELAR_DIAGNOSTIC(batch_metrics_.failures = 1);
    }
    TELAR_DIAGNOSTIC(batch_metrics_.prepared_frames = prepared_.takePreparedCount());
    TELAR_DIAGNOSTIC(batch_metrics_.resets = reset);
    return reset;
  }

#if TELAR_DIAGNOSTICS
  diagnostics::GraphicsStorageSnapshot storageMetrics() {
    if (busy_) {
      return {.busy_panes = 1};
    }

    auto sample = terminal_ ? terminal_->storageMetrics() : diagnostics::GraphicsStorageSnapshot{};
    sample.prepared_bytes = prepared_.storedBytes();
    sample.staged_bytes = requests_.storedBytes();
    return sample;
  }

  const diagnostics::MediaQueue &queueMetrics() const noexcept {
    return queue_metrics_;
  }

  void noteHeldRead() noexcept {
    diagnostics::accumulate(queue_metrics_.held_reads);
  }

  std::size_t usedBytes() const noexcept {
    return memory_.used();
  }

  const diagnostics::MediaCounters &batchMetrics() const noexcept {
    return batch_metrics_;
  }
#endif

  bool busy() const noexcept {
    return busy_;
  }

  void noteSharedTransport(bool added) noexcept {
    if (added) {
      shared_clients_.fetch_add(1, std::memory_order_release);
    } else {
      shared_clients_.fetch_sub(1, std::memory_order_release);
    }
  }

  std::optional<FrozenImage<Memory>> takeTransfer(ImageKey key, bool shared) {
    if (shared) {
      if (auto prepared = prepared_.take(key)) {
        return prepared;
      }
    }
    auto frozen = requests_.take(key, shared);
    if (!frozen && requests_.request(key, shared)) {
      output({});
    }
    return frozen;
  }

  template <typename Consumer>
  void discardUnwantedTransfers(const Consumer &wanted) noexcept {
    prepared_.discardUnwanted(wanted);
    requests_.discardUnwanted(wanted);
  }

  bool idle() const noexcept {
    return !busy_ && batches_[active_].events().empty();
  }

  MediaTerminal<AllocatedMemory> *terminal() noexcept {
    return busy_ || !terminal_ ? nullptr : &*terminal_;
  }

  std::uint64_t takeDroppedBytes() noexcept {
    return std::exchange(dropped_bytes_, 0);
  }

  std::uint64_t takeFailures() noexcept {
    return std::exchange(failures_, 0);
  }

  std::shared_ptr<PaneMedia> retired_next;

private:
#if TELAR_DIAGNOSTICS
  void observeQueue() noexcept {
    queue_metrics_.observe(batches_[0].events().size() + batches_[1].events().size(), batches_[0].byteCount() + batches_[1].byteCount());
  }
#endif

  void dropActive(std::size_t incoming) noexcept {
    auto &batch = batches_[active_];
    TELAR_DIAGNOSTIC(diagnostics::accumulate(queue_metrics_.dropped_events, batch.events().size() + 1));
    TELAR_DIAGNOSTIC(diagnostics::accumulate(queue_metrics_.dropped_bytes, batch.byteCount() + incoming));
    dropped_bytes_ += batch.byteCount() + incoming;
    batch.clear();
    batch.reset_before = true;
  }

  AllocatedMemory memory_;
  PreparedImages<Memory> prepared_;
  TransferRequests<Memory> requests_;
  std::shared_ptr<PtyResponseQueue> responses_;
  GraphicsLimits limits_;
  std::optional<MediaTerminal<AllocatedMemory>> terminal_;
  std::array<MediaBatch, 2> batches_;
  std::array<Byte, MediaBatch::byte_capacity> scratch_;
  KittyFraming framing_;
  TerminalSize current_size_;
  TerminalSize sealed_size_{};
  std::size_t active_ = 0;
  std::size_t sealed_ = 0;
  std::uint64_t dropped_bytes_ = 0;
  std::uint64_t failures_ = 0;
#if TELAR_DIAGNOSTICS
  diagnostics::MediaCounters batch_metrics_;
  diagnostics::MediaQueue queue_metrics_;
#endif
  bool busy_ = false;
  std::atomic<unsigned> shared_clients_{0};
};

}
