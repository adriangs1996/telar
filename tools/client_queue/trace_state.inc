
  // Client queue trace (instrument.py): one entry per queued frame, in byte order, and the deferred
  // responses' queue times in order.
  std::vector<TraceEntry> trace_entries_;
  std::vector<std::uint64_t> trace_deferred_;
  std::uint64_t trace_busy_since_ = 0;
  std::uint64_t trace_busy_bytes_ = 0;
  std::uint32_t trace_queue_ = queue_trace::nextQueue();
  DeliveryLane trace_active_lane_ = DeliveryLane::count;
