// Client queue trace: measurement only. instrument.py pastes this into a copy of the runtime; it is never
// committed to the runtime itself.
namespace telar::runtime::queue_trace {
  enum class Kind : std::uint8_t {
    message,
    dropped,
    drain,
    snapshot,
    write,
    stop_request,
    mismatch,
    publish,
    mark,
  };

  // 40 bytes, read by analyze.py. The meaning of each field depends on the kind.
  struct Record {
    std::uint64_t first = 0;
    std::uint64_t second = 0;
    std::uint32_t bytes = 0;
    std::uint32_t extra = 0;
    std::uint32_t mask = 0;
    std::uint32_t queue = 0;
    Kind kind = Kind::message;
    std::uint8_t lane = 0;
    std::uint16_t phase = 0;
    std::uint32_t frames = 0;
  };

  static_assert(sizeof(Record) == 40);

  QUEUE_TRACE_INLINE bool enabled() noexcept;

  QUEUE_TRACE_INLINE std::uint64_t now() noexcept;

  QUEUE_TRACE_INLINE void record(const Record& record) noexcept;

  QUEUE_TRACE_INLINE void flush() noexcept;

  QUEUE_TRACE_INLINE std::uint32_t nextQueue() noexcept;

  // Page faults and copy-on-write faults of this process so far; zero where the platform has no counter.
  QUEUE_TRACE_INLINE void faults(std::uint32_t& all, std::uint32_t& copy_on_write) noexcept;
}
