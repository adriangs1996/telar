module telar.runtime.diagnostics.operation;

import telar.sys.posix;

namespace telar::runtime::diagnostics {

  template <Allocator Memory>
  FileStorage<Memory>::FileStorage(Memory& memory, std::string_view path)
      : path_(memory, path) {}

  template <Allocator Memory>
  void FileStorage<Memory>::sample(Clock::time_point now) noexcept {
    if (now < next_sample_) {
      return;
    }

    next_sample_ = now + sample_interval;

    struct stat status;
    const bool available = !path_.empty() && path_ != ":memory:" && ::lstat(path_.data(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size >= 0;

    bytes_.store(available ? static_cast<std::uint64_t>(status.st_size) : 0, std::memory_order_relaxed);
  }

  template <Allocator Memory>
  std::uint64_t FileStorage<Memory>::bytes() const noexcept {
    return bytes_.load(std::memory_order_relaxed);
  }

  template class FileStorage<SystemAllocator>;
  template class FileStorage<ConcurrentMemory>;
  template class FileStorage<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  void GraphicsStorageSnapshot::merge(const GraphicsStorageSnapshot& other) noexcept {
    accumulate(images, other.images);
    accumulate(placements, other.placements);
    accumulate(resident_bytes, other.resident_bytes);
    accumulate(loading_bytes, other.loading_bytes);
    accumulate(prepared_bytes, other.prepared_bytes);
    accumulate(staged_bytes, other.staged_bytes);
    accumulate(transfer_bytes, other.transfer_bytes);
    accumulate(busy_panes, other.busy_panes);
  }

  void GraphicsStorageSnapshot::write(Line& line) const {
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

  void MediaQueue::observe(std::size_t event_count, std::size_t byte_count) noexcept {
    events = event_count;
    bytes = byte_count;
    event_high_water = std::max(event_high_water, events);
    byte_high_water = std::max(byte_high_water, bytes);
  }

  void MediaQueue::merge(const MediaQueue& other) noexcept {
    accumulate(events, other.events);
    accumulate(bytes, other.bytes);
    accumulate(event_high_water, other.event_high_water);
    accumulate(byte_high_water, other.byte_high_water);
    accumulate(dropped_events, other.dropped_events);
    accumulate(dropped_bytes, other.dropped_bytes);
    accumulate(held_reads, other.held_reads);
  }

  void MediaQueue::write(Line& line) const {
    line.field("media_queue_events", events);
    line.field("media_queue_bytes", bytes);
    line.field("media_queue_event_high_water", event_high_water);
    line.field("media_queue_byte_high_water", byte_high_water);
    line.field("media_dropped_events", dropped_events);
    line.field("media_dropped_bytes", dropped_bytes);
    line.field("media_held_reads", held_reads);
  }

  void OperationCounters::observe(std::uint64_t duration, bool failed) noexcept {
    total_ns_.fetch_add(duration, std::memory_order_relaxed);
    auto maximum = maximum_ns_.load(std::memory_order_relaxed);

    while (duration > maximum && !maximum_ns_.compare_exchange_weak(maximum, duration, std::memory_order_relaxed)) {
    }

    failures_.fetch_add(failed, std::memory_order_relaxed);
    count_.fetch_add(1, std::memory_order_relaxed);
  }

  OperationSnapshot OperationCounters::snapshot() const noexcept {
    return {{count_.load(std::memory_order_relaxed), total_ns_.load(std::memory_order_relaxed), maximum_ns_.load(std::memory_order_relaxed)}, failures_.load(std::memory_order_relaxed)};
  }

  OperationTimer::OperationTimer(OperationCounters* counters) noexcept
      : counters_(counters),
        started_(counters == nullptr ? Clock::time_point{} : Clock::now()),
        exceptions_(std::uncaught_exceptions()) {}

  OperationTimer::~OperationTimer() {
    if (counters_ != nullptr) {
      counters_->observe(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started_).count(), failed_ || std::uncaught_exceptions() > exceptions_);
    }
  }

  void OperationTimer::fail() noexcept {
    failed_ = true;
  }

  void TerminalStorageSnapshot::merge(const TerminalStorageSnapshot& other) noexcept {
    accumulate(page_bytes, other.page_bytes);
    accumulate(screen_bytes, other.screen_bytes);
  }

  void TerminalStorageSnapshot::write(Line& line) const {
    line.field("vt_scrollback_bytes", page_bytes);
    line.field("vt_screen_bytes", screen_bytes);
  }

}
