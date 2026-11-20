export module telar.runtime.terminal.osc_scanner;

import std;

import telar.base.memory.allocators;
import telar.ghostty.vt;
import telar.wire.vocabulary;
import telar.wire.content;
import telar.runtime.terminal.control;
import telar.runtime.terminal.kitty;
import telar.base.ds;

// Interface: terminal/frame_pacer.cppm
export {
  namespace telar::runtime {

    class FramePacer {
    public:
      using Clock = std::chrono::steady_clock;
      using Time = Clock::time_point;

      void configure(std::chrono::nanoseconds interval) noexcept;

      void noteInput(Time time) noexcept;

      [[nodiscard]] ds::Option<Time> deadline(Time now) const noexcept;

      void record(Time now, ds::Option<Time> scheduled) noexcept;

    private:
      [[nodiscard]] unsigned available(Time now) const noexcept;

      static constexpr unsigned idle_burst = 4;
      static constexpr unsigned input_burst = 16;
      static constexpr auto input_grace = std::chrono::milliseconds{30};
      std::chrono::nanoseconds interval_{1'000'000'000 / 60};
      ds::Option<Time> anchor_;
      ds::Option<Time> last_input_;
      unsigned credits_ = idle_burst;
      unsigned input_frames_left_ = 0;
    };

  }
}

// Interface: terminal/input_scanner.cppm
export {
  namespace telar::runtime {

    enum class ControlByte : std::uint8_t {
      cancel = 0x03,
      bell = 0x07,
      backspace = 0x08,
      newline = 0x0a,
      clear_screen = 0x0c,
      carriage_return = 0x0d,
      escape = 0x1b,
      delete_previous = 0x7f,
    };

    struct InputEvent {
      bool submitted = false;
      bool cancelled = false;
    };

    class InputScanner {
    public:
      InputEvent feed(std::span<const std::uint8_t> bytes) noexcept;

      void reset() noexcept;

      void clearSensitive() noexcept;

      [[nodiscard]] ds::Option<std::string_view> typedText() const noexcept;

    private:
      enum class State {
        ground,
        escape,
        csi,
        paste,
        paste_escape,
        paste_csi,
      };
      enum class PasteMarker : std::uint16_t {
        begin = 200,
        end = 201,
      };
      static constexpr std::size_t maximum_typed_bytes = 255;

      void consume(std::uint8_t byte, InputEvent& event) noexcept;

      void startSequence(State state) noexcept;

      void sequenceByte(std::uint8_t byte, bool pasted) noexcept;

      State state_ = State::ground;
      std::uint16_t parameter_ = 0;
      bool has_parameter_ = false;
      ds::Array<char, maximum_typed_bytes> typed_;
      std::size_t typed_length_ = 0;
      bool typed_exact_ = true;
    };

  }
}

// Interface: terminal/osc_scanner.cppm
export {
  namespace telar::runtime {

    class OscScanner {
    public:
      enum class Event {
        none,
        start,
        payload,
        end,
      };

      Event next(std::uint8_t byte) noexcept;

    private:
      enum class State {
        ground,
        escape,
        osc,
        osc_escape,
      };
      State state_ = State::ground;
    };

  }
}

// Interface: terminal/response_outbox.cppm
export {
  namespace telar::runtime {

    // One producer owns these staged messages. Queue publication copies complete
    // records; a blocked record is never executed or generated a second time.
    template <Allocator Memory>
    class ResponseOutbox {
    public:
      // The outbox shares the queue it fills, so it keeps no borrow of whoever else holds it.
      explicit ResponseOutbox(Memory& memory, std::shared_ptr<PtyResponseQueue> queue);

      ~ResponseOutbox();

      ResponseOutbox(const ResponseOutbox&) = delete;
      ResponseOutbox& operator=(const ResponseOutbox&) = delete;

      void append(std::span<const std::uint8_t> response);

      bool drain() noexcept;

      void discard() noexcept;

      [[nodiscard]] bool pending() const noexcept;

      [[nodiscard]] std::size_t nextSize() const noexcept;

    private:
      static constexpr std::size_t inline_bytes = 2048;
      static constexpr std::size_t maximum_bytes = PtyResponseQueue::total_byte_capacity;
      static constexpr std::size_t header_bytes = sizeof(std::uint16_t);
      ds::Array<std::uint8_t, inline_bytes> inline_;
      ds::Vec<std::uint8_t, Memory> overflow_;
      std::shared_ptr<PtyResponseQueue> queue_;
      std::size_t size_ = 0;
      std::size_t consumed_ = 0;
      bool priority_ = false;
    };

    extern template class ResponseOutbox<telar::ConcurrentMemory>;
    extern template class ResponseOutbox<telar::runtime::MediaAllocator<telar::ConcurrentMemory>>;

  }
}

// Interface: terminal/text_search.cppm
export {
  namespace telar::runtime {

    class TextSearch {
    public:
      explicit TextSearch(const SearchPane& request, std::uint64_t revision);

      // A search of the rows from `first_row` to `last_row` only.
      explicit TextSearch(const SearchPaneRows& request, std::uint64_t revision);

      bool advance(GhosttyTerminal terminal, std::uint64_t revision);

      PaneMatches result();

      std::uint64_t request_id;
      std::uint64_t pane_id;

    private:
      // The rows a search may read, both ends included.
      struct Rows {
        std::uint32_t first = 0;
        std::uint32_t last = std::numeric_limits<std::uint32_t>::max();
      };

      TextSearch(std::uint64_t request, std::uint64_t pane, std::string_view needle, Rows rows, std::uint64_t revision);

      [[nodiscard]] std::uint32_t normalize(std::uint32_t codepoint) const noexcept;

      bool searchRow(GhosttyTerminal terminal, std::uint32_t row);

      using Clock = std::chrono::steady_clock;
      static constexpr std::size_t maximum_rows = 50000;
      static constexpr std::size_t maximum_columns = 512;
      static constexpr std::size_t rows_per_turn = 32;
      static constexpr auto deadline_budget = std::chrono::milliseconds{(maximum_rows + rows_per_turn - 1) / rows_per_turn};
      ds::Array<std::uint32_t, 128> needle_{};
      ds::Array<std::size_t, 128> prefix_{};
      ds::Array<PaneMatch, 256> matches_{};
      Rows rows_;
      std::uint64_t revision_;
      Clock::time_point deadline_;
      std::size_t needle_length_ = 0;
      std::size_t next_row_ = 0;
      std::size_t first_row_ = 0;
      std::size_t count_ = 0;
      std::uint16_t columns_ = 0;
      bool fold_ascii_ = true;
      bool truncated_ = false;
      bool started_ = false;
    };

  }
}
