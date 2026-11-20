export module telar.runtime.diagnostics.operation;

import std;

import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.runtime.diagnostics.line;
import telar.base.ds;

// Interface: diagnostics/file_storage.cppm
export {
  namespace telar::runtime::diagnostics {

    template <Allocator Memory>
    class FileStorage {
    public:
      using Clock = std::chrono::steady_clock;

      explicit FileStorage(Memory& memory, std::string_view path);

      void sample(Clock::time_point now) noexcept;
      std::uint64_t bytes() const noexcept;

    private:
      static constexpr auto sample_interval = std::chrono::seconds{1};
      ds::String<Memory> path_;
      Clock::time_point next_sample_;
      std::atomic<std::uint64_t> bytes_{0};
    };

    extern template class FileStorage<SystemAllocator>;
    extern template class FileStorage<ConcurrentMemory>;
    extern template class FileStorage<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

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

      void merge(const GraphicsStorageSnapshot& other) noexcept;
      void write(Line& line) const;
    };

  }
}

// Interface: diagnostics/media_queue.cppm
export {
  namespace telar::runtime::diagnostics {

    // What a media queue holds at one moment: its events and their bytes.
    struct QueueDepth {
      std::size_t events = 0;
      std::size_t bytes = 0;
    };

    struct MediaQueue {
      std::uint64_t events = 0;
      std::uint64_t bytes = 0;
      std::uint64_t event_high_water = 0;
      std::uint64_t byte_high_water = 0;
      std::uint64_t dropped_events = 0;
      std::uint64_t dropped_bytes = 0;
      std::uint64_t held_reads = 0;

      void observe(QueueDepth depth) noexcept;
      void merge(const MediaQueue& other) noexcept;
      void write(Line& line) const;
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
      void observe(std::uint64_t duration, bool failed) noexcept;
      OperationSnapshot snapshot() const noexcept;

    private:
      std::atomic<std::uint64_t> count_{0};
      std::atomic<std::uint64_t> total_ns_{0};
      std::atomic<std::uint64_t> maximum_ns_{0};
      std::atomic<std::uint64_t> failures_{0};
    };

    class OperationTimer {
    public:
      using Clock = std::chrono::steady_clock;

      explicit OperationTimer(OperationCounters* counters) noexcept;
      ~OperationTimer();

      OperationTimer(const OperationTimer&) = delete;
      OperationTimer& operator=(const OperationTimer&) = delete;
      OperationTimer(OperationTimer&&) = delete;
      OperationTimer& operator=(OperationTimer&&) = delete;

      void fail() noexcept;

    private:
      OperationCounters* counters_;
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

      void merge(const TerminalStorageSnapshot& other) noexcept;
      void write(Line& line) const;
    };

  }
}
