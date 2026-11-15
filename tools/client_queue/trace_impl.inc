// Client queue trace recorder: a fixed buffer the runtime flushes once, at the end of stop().
namespace telar::runtime::queue_trace {
  namespace detail {
    inline constexpr std::size_t capacity = std::size_t{1} << 22;

    struct State {
      const char* directory = nullptr;
      Record* records = nullptr;
      std::atomic<std::size_t> next{0};
      std::atomic<std::uint32_t> queues{0};
      std::size_t flushed = 0;
    };

    QUEUE_TRACE_INLINE State& state() noexcept {
      static State* const instance = [] {
        auto* created = new State;

        created->directory = std::getenv("QUEUE_TRACE_DIR");
        if (created->directory != nullptr && created->directory[0] != '\0') {
          void* memory = ::mmap(nullptr, capacity * sizeof(Record), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
          if (memory != MAP_FAILED) {
            created->records = static_cast<Record*>(memory);
          }
        }

        return created;
      }();

      return *instance;
    }
  }

  QUEUE_TRACE_INLINE bool enabled() noexcept {
    return detail::state().records != nullptr;
  }

  QUEUE_TRACE_INLINE std::uint64_t now() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
  }

  QUEUE_TRACE_INLINE void record(const Record& record) noexcept {
    auto& current = detail::state();
    if (current.records == nullptr) {
      return;
    }

    const auto index = current.next.fetch_add(1, std::memory_order_relaxed);
    if (index < detail::capacity) {
      current.records[index] = record;
    }
  }

  QUEUE_TRACE_INLINE void flush() noexcept {
    auto& current = detail::state();
    if (current.records == nullptr) {
      return;
    }

    const auto end = std::min(current.next.load(std::memory_order_relaxed), detail::capacity);
    if (end <= current.flushed) {
      return;
    }

    char path[1024];
    std::snprintf(path, sizeof(path), "%s/queue-%d.bin", current.directory, static_cast<int>(::getpid()));
    const int descriptor = ::open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (descriptor < 0) {
      return;
    }

    const auto* bytes = reinterpret_cast<const char*>(current.records + current.flushed);
    auto remaining = (end - current.flushed) * sizeof(Record);
    while (remaining != 0) {
      const auto count = ::write(descriptor, bytes, remaining);
      if (count <= 0) {
        break;
      }

      bytes += count;
      remaining -= static_cast<std::size_t>(count);
    }

    ::close(descriptor);
    current.flushed = end;
  }

  QUEUE_TRACE_INLINE void faults(std::uint32_t& all, std::uint32_t& copy_on_write) noexcept {
#if defined(__APPLE__)
    task_events_info_data_t events{};
    mach_msg_type_number_t count = TASK_EVENTS_INFO_COUNT;

    if (::task_info(::mach_task_self(), TASK_EVENTS_INFO, reinterpret_cast<task_info_t>(&events), &count) == KERN_SUCCESS) {
      all = static_cast<std::uint32_t>(events.faults);
      copy_on_write = static_cast<std::uint32_t>(events.cow_faults);
    }
#else
    rusage usage{};

    if (::getrusage(RUSAGE_SELF, &usage) == 0) {
      all = static_cast<std::uint32_t>(usage.ru_minflt);
      copy_on_write = 0;
    }
#endif
  }

  QUEUE_TRACE_INLINE std::uint32_t nextQueue() noexcept {
    return detail::state().queues.fetch_add(1, std::memory_order_relaxed) + 1;
  }
}
