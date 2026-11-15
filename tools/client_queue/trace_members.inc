  // Client queue trace: a mirror of the queued frames with the time each one was queued.
  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceAppend(std::size_t size, DeliveryLane lane) noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    const auto now = queue_trace::now();

    try {
      trace_entries_.push_back(TraceEntry{size, now, static_cast<std::uint32_t>(size), lane});
    } catch (...) {
      return;
    }

    if (trace_busy_since_ == 0) {
      trace_busy_since_ = now;
      trace_busy_bytes_ = 0;
    }

    trace_busy_bytes_ += size;
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceDefer() noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    const auto now = queue_trace::now();

    try {
      trace_deferred_.push_back(now);
    } catch (...) {
      return;
    }

    if (trace_busy_since_ == 0) {
      trace_busy_since_ = now;
      trace_busy_bytes_ = 0;
    }
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceInsert(std::size_t offset, std::size_t size, DeliveryLane lane) noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    std::uint64_t enqueued = queue_trace::now();
    if (!trace_deferred_.empty()) {
      enqueued = trace_deferred_.front();
      trace_deferred_.erase(trace_deferred_.begin());
    }

    std::size_t index = 0;
    std::size_t cumulative = 0;
    while (index < trace_entries_.size() && cumulative < offset) {
      cumulative += trace_entries_[index].remaining;
      ++index;
    }

    if (cumulative != offset) {
      queue_trace::record({.first = queue_trace::now(), .bytes = static_cast<std::uint32_t>(offset), .extra = static_cast<std::uint32_t>(cumulative), .queue = trace_queue_, .kind = queue_trace::Kind::mismatch, .phase = 1});
    }

    try {
      trace_entries_.insert(trace_entries_.begin() + static_cast<std::ptrdiff_t>(index), TraceEntry{size, enqueued, static_cast<std::uint32_t>(size), lane});
    } catch (...) {
      return;
    }

    trace_busy_bytes_ += size;
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceConsumed(std::size_t offset, std::size_t count) noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    const auto now = queue_trace::now();
    std::size_t index = 0;
    std::size_t cumulative = 0;
    while (index < trace_entries_.size() && cumulative < offset) {
      cumulative += trace_entries_[index].remaining;
      ++index;
    }

    if (cumulative != offset) {
      queue_trace::record({.first = now, .bytes = static_cast<std::uint32_t>(offset), .extra = static_cast<std::uint32_t>(cumulative), .queue = trace_queue_, .kind = queue_trace::Kind::mismatch, .phase = 2});
    }

    while (count != 0 && index < trace_entries_.size()) {
      auto& entry = trace_entries_[index];
      const auto taken = std::min(count, entry.remaining);

      entry.remaining -= taken;
      count -= taken;
      if (entry.remaining != 0) {
        ++index;
        continue;
      }

      queue_trace::record({.first = entry.enqueued, .second = now, .bytes = entry.size, .extra = static_cast<std::uint32_t>(bytes_.size()), .queue = trace_queue_, .kind = queue_trace::Kind::message, .lane = static_cast<std::uint8_t>(entry.lane), .frames = static_cast<std::uint32_t>(trace_entries_.size())});
      trace_entries_.erase(trace_entries_.begin() + static_cast<std::ptrdiff_t>(index));
    }
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceDrained() noexcept {
    if (trace_busy_since_ == 0 || !empty()) {
      return;
    }

    queue_trace::record({.first = trace_busy_since_, .second = queue_trace::now(), .bytes = static_cast<std::uint32_t>(trace_busy_bytes_), .queue = trace_queue_, .kind = queue_trace::Kind::drain});
    trace_busy_since_ = 0;
    trace_busy_bytes_ = 0;
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceCleared() noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    const auto now = queue_trace::now();
    for (const auto& entry : trace_entries_) {
      queue_trace::record({.first = entry.enqueued, .second = now, .bytes = entry.size, .extra = static_cast<std::uint32_t>(entry.remaining), .queue = trace_queue_, .kind = queue_trace::Kind::dropped, .lane = static_cast<std::uint8_t>(entry.lane)});
    }

    trace_entries_.clear();
    trace_deferred_.clear();
    trace_busy_since_ = 0;
    trace_busy_bytes_ = 0;
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceSnapshot(std::uint16_t phase) const noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    std::uint64_t oldest = 0;
    for (const auto& entry : trace_entries_) {
      if (oldest == 0 || entry.enqueued < oldest) {
        oldest = entry.enqueued;
      }
    }

    for (const auto enqueued : trace_deferred_) {
      if (oldest == 0 || enqueued < oldest) {
        oldest = enqueued;
      }
    }

    queue_trace::record({.first = oldest, .second = queue_trace::now(), .bytes = static_cast<std::uint32_t>(bytes_.size()), .extra = static_cast<std::uint32_t>(active_remaining_), .mask = pending_lanes_, .queue = trace_queue_, .kind = queue_trace::Kind::snapshot, .lane = static_cast<std::uint8_t>(trace_active_lane_), .phase = phase, .frames = static_cast<std::uint32_t>(trace_entries_.size() + (trace_deferred_.size() << 16))});
  }

  template <Allocator Memory>
  void OutgoingFrames<Memory>::traceWrite(std::uint64_t started, std::size_t prepared, long count, int error) const noexcept {
    if (!queue_trace::enabled()) {
      return;
    }

    queue_trace::record({.first = started, .second = queue_trace::now(), .bytes = static_cast<std::uint32_t>(prepared), .extra = static_cast<std::uint32_t>(count > 0 ? count : 0), .mask = static_cast<std::uint32_t>(count < 0 ? error : 0), .queue = trace_queue_, .kind = queue_trace::Kind::write, .lane = static_cast<std::uint8_t>(trace_active_lane_), .frames = static_cast<std::uint32_t>(bytes_.size())});
  }
