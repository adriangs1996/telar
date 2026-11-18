module;
#include "tbc/annotations.hpp"

// What the command history holds and asks for: its rows, filters, searches and the text of a
// command checked for the shell.
export module telar.gui.features.history:entry;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: history/choice.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryChoice {
      std::size_t index = 0;
      std::uint64_t revision = 0;

      bool operator==(const HistoryChoice&) const = default;
    };

  }
}

// Interface: history/entry.cppm
export {
  namespace telar::gui::features::history {

    enum class HistoryPhase : std::uint8_t {
      idle,
      loading,
      ready,
      failed,
    };

    enum class HistoryPage : std::uint8_t {
      older,
      newer,
    };

    struct HistoryFilters {
      HistoryScope scope = HistoryScope::global;
      HistoryAuthorFilter author = HistoryAuthorFilter::human;
      bool failed_only = false;
    };

    struct HistoryViewState {
      HistoryPhase phase = HistoryPhase::idle;
      HistoryPhase command_phase = HistoryPhase::idle;
      HistoryPhase output_phase = HistoryPhase::idle;
      std::uint32_t page_offset = 0;
      std::uint64_t snapshot_id = 0;
      std::uint64_t output_id = 0;
      std::uint64_t command_id = 0;
      std::size_t selection = 0;
      bool has_page = false;
      bool has_more = false;
      bool inspecting = false;
      bool output_truncated = false;
    };

    template <Allocator Memory>
    struct HistoryRow {
      explicit HistoryRow(Memory& memory);

      std::uint64_t id = 0;
      std::uint64_t pane_id = 0;
      ds::String<Memory> command;
      ds::String<Memory> cwd;
      ds::String<Memory> provider;
      std::size_t full_offset = 0;
      std::size_t full_length = 0;
      std::int64_t started_at_ms = 0;
      std::int64_t duration_ns = 0;
      ds::Option<std::int32_t> exit_code;
      HistoryStatus status = HistoryStatus::completed;
      HistoryAuthor author = HistoryAuthor::human;
      HistoryOrigin origin = HistoryOrigin::pane;
      bool command_truncated = false;
      bool command_complete = false;
    };

    extern template struct HistoryRow<telar::Memory>;
    extern template struct HistoryRow<telar::ConcurrentMemory>;
    extern template struct HistoryRow<telar::SystemAllocator>;

  }
}

// Interface: history/search.cppm
export {
  namespace telar::gui::features::history {

    struct HistorySearch {
      static constexpr std::size_t maximum_query_bytes = 128;

      std::string_view query;
      bool failed_only = false;

      [[nodiscard]] static HistorySearch parse(std::string_view text, bool failed_only) noexcept;
    };

  }
}

// What the history keeps of a search and of each command, and how many requests it tracks.
export {
  namespace telar::gui::features::history {

    struct HistoryLimits {
      static constexpr std::uint16_t page_entries = 100;
      static constexpr std::size_t command_preview_bytes = 512;
      static constexpr std::size_t command_cache_bytes = std::size_t{768} * 1024;
      static constexpr std::size_t maximum_command_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t maximum_query_bytes = HistorySearch::maximum_query_bytes;
      static constexpr std::size_t maximum_output_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t maximum_requests = 128;
      static constexpr std::size_t maximum_error_bytes = 128;
    };

  }
}

// Interface: history/plain_text.cppm
export {
  namespace telar::gui::features::history {

    class PlainText {
    public:
      static std::size_t strip(std::span<const Byte> bytes, std::span<char> output) noexcept;

    private:
      enum class State : Byte {
        ground,
        escape,
        intermediate,
        csi,
        string,
        string_escape,
      };

      static constexpr Byte escape = 0x1b;
      static constexpr Byte bell = 0x07;
      static constexpr Byte first_printable = 0x20;
      static constexpr Byte delete_control = 0x7f;
      static constexpr Byte first_intermediate = 0x20;
      static constexpr Byte last_intermediate = 0x2f;
      static constexpr Byte first_escape_final = 0x30;
      static constexpr Byte first_csi_final = 0x40;
      static constexpr Byte last_csi_final = 0x7e;

      static State escapeState(Byte byte) noexcept;

      static State advance(State state, Byte byte) noexcept;
    };

  }
}

// Interface: input/history_text.cppm
export {
  namespace telar::gui::features::history {

    class HistoryText {
    public:
      static constexpr std::size_t maximum_bytes = std::size_t{64} * 1024;

      static void validate(std::string_view text, bool bracketed_paste);

    private:
      static bool isControl(std::string_view text, std::size_t index) noexcept;
    };

  }
}
