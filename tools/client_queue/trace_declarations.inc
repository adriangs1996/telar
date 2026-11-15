  // Client queue trace (instrument.py): the queue as it is now, and one write() that just returned.
  void traceSnapshot(std::uint16_t phase) const noexcept;

  void traceWrite(std::uint64_t started, std::size_t prepared, long count, int error) const noexcept;

private:
  struct TraceEntry {
    std::size_t remaining;
    std::uint64_t enqueued;
    std::uint32_t size;
    DeliveryLane lane;
  };

  void traceAppend(std::size_t size, DeliveryLane lane) noexcept;

  void traceDefer() noexcept;

  void traceInsert(std::size_t offset, std::size_t size, DeliveryLane lane) noexcept;

  void traceConsumed(std::size_t offset, std::size_t count) noexcept;

  void traceDrained() noexcept;

  void traceCleared() noexcept;

public:
