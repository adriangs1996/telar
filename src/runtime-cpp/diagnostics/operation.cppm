module;
#include <cstdlib>
#include <new>

#include <sys/stat.h>


#include <cstddef>
#include <cstdint>

export module telar.runtime.diagnostics.operation;

import std;

import telar.base.diagnostics;
import telar.base.memory;
import telar.runtime.diagnostics.line;


// Interface: diagnostics/file_storage.cppm
export {
namespace telar::runtime::diagnostics {

template <Allocator Memory>
class FileStorage {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit FileStorage(Memory &memory, std::string_view path)
      : path_(path, AllocatorRef<char, Memory>{memory}) {}

  inline void sample(Clock::time_point now) noexcept {
    if (now < next_sample_) {
      return;
    }
    next_sample_ = now + sample_interval;

    struct stat status;
    const bool available = !path_.empty() && path_ != ":memory:" && ::lstat(path_.c_str(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size >= 0;
    bytes_.store(available ? static_cast<std::uint64_t>(status.st_size) : 0, std::memory_order_relaxed);
  }

  inline std::uint64_t bytes() const noexcept {
    return bytes_.load(std::memory_order_relaxed);
  }

private:
  static constexpr auto sample_interval = std::chrono::seconds{1};
  String<Memory> path_;
  Clock::time_point next_sample_{};
  std::atomic<std::uint64_t> bytes_{0};
};

}
}

// Interface: diagnostics/graphics_storage.cppm
export {
namespace telar::runtime::diagnostics {

struct GraphicsStorageSnapshot {
  std::uint64_t images = 0;
  std::uint64_t placements = 0;
  std::uint64_t resident_bytes = 0;
  std::uint64_t loading_bytes = 0;
  std::uint64_t prepared_bytes = 0;
  std::uint64_t staged_bytes = 0;
  std::uint64_t transfer_bytes = 0;
  std::uint64_t busy_panes = 0;

  inline void merge(const GraphicsStorageSnapshot &other) noexcept {
    accumulate(images, other.images);
    accumulate(placements, other.placements);
    accumulate(resident_bytes, other.resident_bytes);
    accumulate(loading_bytes, other.loading_bytes);
    accumulate(prepared_bytes, other.prepared_bytes);
    accumulate(staged_bytes, other.staged_bytes);
    accumulate(transfer_bytes, other.transfer_bytes);
    accumulate(busy_panes, other.busy_panes);
  }

  inline void write(Line &line) const {
    line.field("graphics_images", images);
    line.field("graphics_placements", placements);
    auto resident = resident_bytes;
    accumulate(resident, transfer_bytes);
    line.field("graphics_resident_bytes", resident);
    line.field("graphics_loading_bytes", loading_bytes);
    line.field("graphics_prepared_bytes", prepared_bytes);
    line.field("graphics_staged_bytes", staged_bytes);
    line.field("graphics_transfer_bytes", transfer_bytes);
    line.field("graphics_busy_panes", busy_panes);
  }
};

}
}

// Interface: diagnostics/media_queue.cppm
export {
namespace telar::runtime::diagnostics {

struct MediaQueue {
  std::uint64_t events = 0;
  std::uint64_t bytes = 0;
  std::uint64_t event_high_water = 0;
  std::uint64_t byte_high_water = 0;
  std::uint64_t dropped_events = 0;
  std::uint64_t dropped_bytes = 0;
  std::uint64_t held_reads = 0;

  inline void observe(std::size_t event_count, std::size_t byte_count) noexcept {
    events = event_count;
    bytes = byte_count;
    event_high_water = std::max(event_high_water, events);
    byte_high_water = std::max(byte_high_water, bytes);
  }

  inline void merge(const MediaQueue &other) noexcept {
    accumulate(events, other.events);
    accumulate(bytes, other.bytes);
    accumulate(event_high_water, other.event_high_water);
    accumulate(byte_high_water, other.byte_high_water);
    accumulate(dropped_events, other.dropped_events);
    accumulate(dropped_bytes, other.dropped_bytes);
    accumulate(held_reads, other.held_reads);
  }

  inline void write(Line &line) const {
    line.field("media_queue_events", events);
    line.field("media_queue_bytes", bytes);
    line.field("media_queue_event_high_water", event_high_water);
    line.field("media_queue_byte_high_water", byte_high_water);
    line.field("media_dropped_events", dropped_events);
    line.field("media_dropped_bytes", dropped_bytes);
    line.field("media_held_reads", held_reads);
  }
};

}
}

// Interface: diagnostics/operation.cppm
export {
namespace telar::runtime::diagnostics {

struct OperationSnapshot {
  Timing timing;
  std::uint64_t failures = 0;
};

class OperationCounters {
public:
  inline void observe(std::uint64_t duration, bool failed) noexcept {
    total_ns_.fetch_add(duration, std::memory_order_relaxed);
    auto maximum = maximum_ns_.load(std::memory_order_relaxed);
    while (duration > maximum && !maximum_ns_.compare_exchange_weak(maximum, duration, std::memory_order_relaxed)) {
    }

    failures_.fetch_add(failed, std::memory_order_relaxed);
    count_.fetch_add(1, std::memory_order_relaxed);
  }

  inline OperationSnapshot snapshot() const noexcept {
    return {{count_.load(std::memory_order_relaxed), total_ns_.load(std::memory_order_relaxed), maximum_ns_.load(std::memory_order_relaxed)}, failures_.load(std::memory_order_relaxed)};
  }

private:
  std::atomic<std::uint64_t> count_{0};
  std::atomic<std::uint64_t> total_ns_{0};
  std::atomic<std::uint64_t> maximum_ns_{0};
  std::atomic<std::uint64_t> failures_{0};
};

class OperationTimer {
public:
  using Clock = std::chrono::steady_clock;

  inline explicit OperationTimer(OperationCounters *counters) noexcept
      : counters_(counters), started_(counters == nullptr ? Clock::time_point{} : Clock::now()), exceptions_(std::uncaught_exceptions()) {}

  inline ~OperationTimer() {
    if (counters_ != nullptr) {
      counters_->observe(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started_).count(), failed_ || std::uncaught_exceptions() > exceptions_);
    }
  }

  OperationTimer(const OperationTimer &) = delete;
  OperationTimer &operator=(const OperationTimer &) = delete;

  inline void fail() noexcept {
    failed_ = true;
  }

private:
  OperationCounters *counters_;
  Clock::time_point started_;
  int exceptions_;
  bool failed_ = false;
};

}
}

// Interface: diagnostics/request_queue.cppm
export {
namespace telar::runtime::diagnostics {

struct RequestQueueSnapshot {
  std::size_t depth = 0;
  std::size_t high_water = 0;
  std::uint64_t dropped = 0;
};

}
}

// Interface: diagnostics/terminal_storage.cppm
export {
namespace telar::runtime::diagnostics {

struct TerminalStorageSnapshot {
  std::uint64_t page_bytes = 0;
  std::uint64_t screen_bytes = 0;

  inline void merge(const TerminalStorageSnapshot &other) noexcept {
    accumulate(page_bytes, other.page_bytes);
    accumulate(screen_bytes, other.screen_bytes);
  }

  inline void write(Line &line) const {
    line.field("vt_scrollback_bytes", page_bytes);
    line.field("vt_screen_bytes", screen_bytes);
  }
};

}
}
