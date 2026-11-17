export module telar.gui.peek.screen;

import std;

import telar.gui.foundation.model;

import telar.base.memory.allocators;
import telar.wire.content;
import telar.wire.vocabulary;

// Interface: peek/command.cppm
export {
  namespace telar::gui {

    enum class PeekCommand : std::uint8_t {
      open,
      stop,
      diff,
      message,
    };

    struct PeekInput {
      [[nodiscard]] static PeekCommand command(std::string_view text) noexcept;
    };

  }
}

// Interface: peek/limits.cppm
export {
  namespace telar::gui {

    struct PeekLimits {
      static constexpr std::uint16_t rows = 16;
      static constexpr std::size_t row_cells = 256;
      static constexpr std::size_t cell_bytes = 4;
      static constexpr std::size_t text_bytes = rows * row_cells * cell_bytes;
      static constexpr std::size_t message_bytes = SuggestionLimits::request_bytes;
    };

  }
}

// Interface: peek/target.cppm
export {
  namespace telar::gui {

    struct PeekTarget {
      AgentNavigationTarget agent;
      decltype(AgentSnapshotEntry::session_id) session{};

      bool operator==(const PeekTarget&) const noexcept = default;
    };

  }
}

// Interface: peek/screen.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    class PeekScreen {
    public:
      explicit PeekScreen(Memory& memory);

      void show(PeekTarget target) noexcept;
      void close() noexcept;

      [[nodiscard]] const std::optional<PeekTarget>& target() const noexcept;
      [[nodiscard]] std::string_view text() const noexcept;
      [[nodiscard]] std::uint64_t revision() const noexcept;
      [[nodiscard]] bool reading() const noexcept;
      [[nodiscard]] bool owns(std::uint64_t request) const noexcept;
      [[nodiscard]] std::optional<ReadPane> request(std::uint64_t identity);
      bool fail(std::uint64_t identity) noexcept;
      [[nodiscard]] std::optional<std::size_t> store(const PaneText& reply);
      [[nodiscard]] static std::string_view lastLines(std::string_view text, std::uint16_t count) noexcept;

    private:
      String<Memory> text_;
      std::optional<PeekTarget> target_;
      std::uint64_t request_id_ = 0;
      std::uint64_t revision_ = 0;
    };

    extern template class PeekScreen<telar::Memory>;
    extern template class PeekScreen<telar::ConcurrentMemory>;
    extern template class PeekScreen<telar::SystemAllocator>;

  }
}
