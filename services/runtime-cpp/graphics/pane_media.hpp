#pragma once

#include "../diagnostics/media_counters.hpp"
#include "../diagnostics/media_queue.hpp"
#include "kitty_framing.hpp"
#include "media_batch.hpp"
#include "media_budget.hpp"
#include "media_input.hpp"
#include "media_terminal.hpp"
#include "prepared_images.hpp"
#include "telar_base/diagnostics/config.hpp"
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

  void requireOrderedInput() noexcept { ordered_input_ = true; }

  void output(std::span<const Byte> bytes) noexcept {
    if (cancelled_) {
      return;
    }
    const bool kitty = framing_.touches(bytes);
    auto &batch = batches_[active_];
    if (!batch.append(bytes)) {
      if (ordered_input_) {
        ingress_failed_ = true;
        responses_->stopProducing();
        return;
      }
      dropActive(bytes.size());
      batch.append(bytes);
    }
    batch.kitty |= kitty;
    TELAR_DIAGNOSTIC(observeQueue());
  }

  void resize(TerminalSize size) noexcept {
    if (cancelled_) {
      return;
    }
    current_size_ = size;
    auto &batch = batches_[active_];
    if (!batch.resize(size)) {
      if (ordered_input_) {
        ingress_failed_ = true;
        responses_->stopProducing();
        return;
      }
      dropActive(0);
      batch.resize(size);
    }
    TELAR_DIAGNOSTIC(observeQueue());
  }

  bool holdsRead(std::size_t bytes) const noexcept {
    return pending_responses_ || (!batches_[active_].hasReadCapacity(bytes) && (ordered_input_ || (busy_ && (batches_[active_].kitty || batches_[sealed_].kitty || framing_.inside()))));
  }

  bool seal() noexcept {
    if (busy_) {
      return false;
    }
    if (cancelled_ || responses_->closed()) {
      cancel();
      return false;
    }
    if (pending_responses_) {
      if (!responses_->hasCapacityFor(next_response_bytes_)) {
        return false;
      }
      drain_only_ = true;
      busy_ = true;
      return true;
    }
    if (batches_[active_].events().empty()) {
      return false;
    }

    drain_only_ = false;
    sealed_ = active_;
    active_ ^= 1;
    sealed_size_ = current_size_;
    busy_ = true;
    return true;
  }

  void complete() noexcept {
    if (!drain_only_) {
      batches_[sealed_].clear();
    }
    pending_responses_ = progress_.pending_responses;
    next_response_bytes_ = progress_.next_response_bytes;
    failed_ = progress_.failed;
    busy_ = false;
    if (cancelled_ || progress_.cancelled) {
      cancel();
    }
    TELAR_DIAGNOSTIC(observeQueue());
  }

  bool process() noexcept {
    progress_ = {};
    TELAR_DIAGNOSTIC(batch_metrics_ = {});
    if (responses_->closed()) {
      progress_.cancelled = true;
      return false;
    }
    if (drain_only_) {
      if (terminal_) {
        terminal_->drainResponses();
        responseProgress();
      }
      return false;
    }
    TELAR_TRACE("media.process");
    TELAR_DIAGNOSTIC(AllocationScope allocation_scope{AllocationPath::media});
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
          [[maybe_unused]] const auto statistics = input.feed(batch.bytes(*output));
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
      progress_.failed = !responses_->closed() || (terminal_ && terminal_->responseFailed());
      progress_.cancelled = !progress_.failed;
      responses_->stopProducing();
      prepared_.clear();
      requests_.clear();
      terminal_.reset();
      reset = true;
      TELAR_DIAGNOSTIC(batch_metrics_.failures = progress_.failed);
    }
    responseProgress();
    TELAR_DIAGNOSTIC(batch_metrics_.prepared_frames = prepared_.takePreparedCount());
    TELAR_DIAGNOSTIC(batch_metrics_.resets = reset);
    return reset;
  }

  // Only the runtime calls cancel/complete. A busy worker observes the closed
  // queue, then ownership returns through ObservationWorker before cleanup.
  void cancel() noexcept {
    cancelled_ = true;
    responses_->close();
    if (!busy_) {
      batches_[0].clear();
      batches_[1].clear();
      terminal_.reset();
      prepared_.clear();
      requests_.clear();
      pending_responses_ = false;
      next_response_bytes_ = 0;
    }
  }

  bool failed() const noexcept { return failed_ || ingress_failed_; }

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

  MediaUsage &queryUsage() noexcept {
    return memory_.usage();
  }

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
    return !busy_ && !pending_responses_ && batches_[active_].events().empty();
  }

  MediaTerminal<AllocatedMemory> *terminal() noexcept {
    return busy_ || !terminal_ ? nullptr : &*terminal_;
  }

  std::uint64_t takeDroppedBytes() noexcept {
    return std::exchange(dropped_bytes_, 0);
  }

  std::shared_ptr<PaneMedia> retired_next;

private:
  void responseProgress() noexcept {
    if (terminal_) {
      terminal_->drainResponses();
      progress_.pending_responses = terminal_->pendingResponses();
      progress_.next_response_bytes = terminal_->nextResponseSize();
    }
    progress_.cancelled |= responses_->closed() && !progress_.failed;
  }

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
  KittyFraming framing_;
  TerminalSize current_size_;
  TerminalSize sealed_size_{};
  std::size_t active_ = 0;
  std::size_t sealed_ = 0;
  std::uint64_t dropped_bytes_ = 0;
#if TELAR_DIAGNOSTICS
  diagnostics::MediaCounters batch_metrics_;
  diagnostics::MediaQueue queue_metrics_;
#endif
  bool busy_ = false;
  bool ordered_input_ = false;
  bool ingress_failed_ = false;
  bool drain_only_ = false;
  bool pending_responses_ = false;
  bool failed_ = false;
  bool cancelled_ = false;
  std::size_t next_response_bytes_ = 0;
  // The worker owns Progress while busy; complete imports it only after the
  // ObservationWorker acquire boundary. Runtime scheduling reads copied facts.
  struct Progress {
    std::size_t next_response_bytes = 0;
    bool pending_responses = false;
    bool failed = false;
    bool cancelled = false;
  } progress_;
  std::atomic<unsigned> shared_clients_{0};
};

}
