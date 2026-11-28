module;

// What the command history holds and asks for: its rows, filters, searches and the text of a
// command checked for the shell.
export module telar.gui.features.history:entry;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
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

    // What the page request in flight reads. A search and a page replace the rows shown, so the
    // panel waits for them; a refresh reads the same rows anew and leaves them usable meanwhile.
    enum class HistoryLoad : std::uint8_t {
      none,
      search,
      page,
      refresh,
    };

    // Which request a failure was for: a delete that failed must bring its row back.
    enum class HistoryFailure : std::uint8_t {
      none,
      page,
      detail,
      erase,
    };

    // A filter a person types into the search as its name, a colon and a value, `cwd:src`.
    enum class HistoryFilterKey : std::uint8_t {
      cwd,
      workspace,
      exit,
      since,
      until,
      by,
      host,
      branch,
      shell,
      took,
      // How the panel lists and searches: its order, what it searches, the runs it shows around
      // each match, and how the query matches a command.
      sort,
      output,
      raw,
      mode,
    };

    // How a query matches a command, as the panel names each way and steps through them.
    struct HistoryModes {
      // Each mode's name, in the order of HistoryMatch.
      static constexpr ds::Array<std::string_view, 4> names{"substring", "fuzzy", "prefix", "regex"};

      [[nodiscard]] static constexpr std::string_view name(HistoryMatch mode) noexcept {
        const auto index = static_cast<std::size_t>(mode);

        return index < names.size() ? names[index] : std::string_view{};
      }

      // The mode `name` names; none for any other word.
      [[nodiscard]] static constexpr ds::Option<HistoryMatch> named(std::string_view name) noexcept {
        for (std::size_t index = 0; index < names.size(); ++index) {
          if (names[index] == name) {
            return static_cast<HistoryMatch>(index);
          }
        }

        return {};
      }

      // The mode after `mode` as a key steps them: fuzzy, substring, prefix, regex, and fuzzy again.
      [[nodiscard]] static constexpr HistoryMatch next(HistoryMatch mode) noexcept {
        switch (mode) {
        case HistoryMatch::fuzzy:
          return HistoryMatch::substring;
        case HistoryMatch::substring:
          return HistoryMatch::prefix;
        case HistoryMatch::prefix:
          return HistoryMatch::regex;
        case HistoryMatch::regex:
          break;
        }

        return HistoryMatch::fuzzy;
      }
    };

    // A typed filter that is not one of the panel's own (scope, author, failed), shown as a chip.
    struct HistoryChip {
      static constexpr std::size_t value_capacity = 128;

      HistoryFilterKey key = HistoryFilterKey::cwd;
      BoundedText<value_capacity> value;

      bool operator==(const HistoryChip& other) const noexcept;
    };

    // The chips of a search, in the order they were typed, one per key.
    class HistoryChips {
    public:
      static constexpr std::size_t capacity = 8;

      [[nodiscard]] std::span<const HistoryChip> view() const noexcept;

      [[nodiscard]] ds::Option<std::string_view> value(HistoryFilterKey key) const noexcept;

      // The chip of `key` holds `value` now, in place of the one it held; false when `value` is
      // empty or does not fit.
      bool set(HistoryFilterKey key, std::string_view value);

      // Removes chip `index`; false when there is none.
      bool remove(std::size_t index) noexcept;

      bool operator==(const HistoryChips& other) const noexcept;

    private:
      ds::Array<HistoryChip, capacity> chips_{};
      std::size_t count_ = 0;
    };

    struct HistoryFilters {
      HistoryScope scope = HistoryScope::global;
      HistoryAuthorFilter author = HistoryAuthorFilter::human;
      bool failed_only = false;
      // With the pane scope: the commands from before the pane started too, as a shell's own
      // history holds what came before it.
      bool preload = false;
      HistoryChips chips;
    };

    // The bytes a query matched, as the runtime marked them: into a row's command, or into its
    // excerpt of the output.
    class HistoryMarks {
    public:
      static constexpr std::size_t capacity = max_history_match_ranges;

      [[nodiscard]] std::span<const HistoryRange> view() const noexcept;

      // Keeps the first `capacity` of `ranges`.
      void assign(std::span<const HistoryRange> ranges) noexcept;

      bool operator==(const HistoryMarks& other) const noexcept;

    private:
      ds::Array<HistoryRange, capacity> ranges_{};
      std::size_t count_ = 0;
    };

    // How every run of the selected command went, as the runtime counts them.
    struct HistoryRunStats {
      // The days the inspector counts the runs of, today the last.
      static constexpr std::size_t days = 14;

      std::uint64_t runs = 0;
      // The runs whose end the shell told with how long they took, and their mean.
      std::uint64_t measured = 0;
      std::uint64_t mean_duration_ms = 0;
      // The runs that ended with a status and were not interrupted, and those of them whose status
      // was 0.
      std::uint64_t ended = 0;
      std::uint64_t succeeded = 0;
      // When the newest run started, and the status it ended with.
      std::int64_t last_started_ms = 0;
      ds::Option<std::int32_t> last_exit;
      // The runs started in each of the last `days` local days, the oldest first.
      ds::Array<std::uint32_t, days> per_day{};
    };

    // A command run just before or just after the one inspected, in its pane.
    struct HistoryContextEntry {
      std::string_view command;
      // Run after the one inspected.
      bool newer = false;
    };

    struct HistoryViewState {
      HistoryPhase phase = HistoryPhase::idle;
      HistoryPhase command_phase = HistoryPhase::idle;
      HistoryPhase output_phase = HistoryPhase::idle;
      HistoryPhase runs_phase = HistoryPhase::idle;
      HistoryPhase context_phase = HistoryPhase::idle;
      HistoryLoad load = HistoryLoad::none;
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
      ds::String<Memory> host;
      // A piece of the captured output around the match, when the search read the output.
      ds::String<Memory> excerpt;
      HistoryMarks ranges;
      HistoryMarks excerpt_ranges;
      std::size_t full_offset = 0;
      std::size_t full_length = 0;
      std::int64_t started_at_ms = 0;
      std::int64_t duration_ns = 0;
      ds::Option<std::int32_t> exit_code;
      HistoryStatus status = HistoryStatus::completed;
      HistoryAuthor author = HistoryAuthor::human;
      HistoryOrigin origin = HistoryOrigin::pane;
      // The runs of this command the history keeps; 0 when the runtime did not count them.
      std::uint32_t run_count = 0;
      bool command_truncated = false;
      bool command_complete = false;
      // A run a raw listing shows around a match, which does not match itself.
      bool neighbour = false;
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
      // The commands marked to be used together, and the bytes of them all: what one paste holds.
      static constexpr std::size_t maximum_marks = 32;
      static constexpr std::size_t maximum_marked_bytes = std::size_t{64} * 1024;
      // The commands the inspector shows before and after the one inspected, on each side.
      static constexpr std::size_t context_entries = 3;
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
