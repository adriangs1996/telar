export module telar.gui.history.browser;

import std;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.gui.foundation.core;
import telar.wire.history;
import telar.wire.vocabulary;

// Interface: history/choice.cppm
export {
  namespace telar::gui {

    struct HistoryChoice {
      std::size_t index = 0;
      std::uint64_t revision = 0;

      bool operator==(const HistoryChoice&) const = default;
    };

  }
}

// Interface: history/entry.cppm
export {
  namespace telar::gui {

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
      String<Memory> command;
      String<Memory> cwd;
      String<Memory> provider;
      std::size_t full_offset = 0;
      std::size_t full_length = 0;
      std::int64_t started_at_ms = 0;
      std::int64_t duration_ns = 0;
      std::optional<std::int32_t> exit_code;
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

// Interface: history/page_storage.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    class HistoryPageStorage {
    public:
      static constexpr std::size_t maximum_entries = 100;
      static constexpr std::size_t command_preview_bytes = 512;
      static constexpr std::size_t command_cache_bytes = std::size_t{768} * 1024;

      explicit HistoryPageStorage(tbc::view<Memory&, tbc::lt::a> memory, std::span<const HistoryEntry> entries = {});

      void exchangeWith(HistoryPageStorage& other);

      [[nodiscard]] const Vector<HistoryRow<Memory>, Memory>& rows() const noexcept;

      [[nodiscard]] std::string_view command(std::size_t index) const;

    private:
      static std::size_t commandBytes(std::span<const HistoryEntry> entries);

      void append(tbc::view<Memory&, tbc::lt::a> memory, const HistoryEntry& entry);

      tbc::view<Vector<HistoryRow<Memory>, Memory>, tbc::lt::a> rows_;
      tbc::view<String<Memory>, tbc::lt::a> commands_;
    };

    extern template class HistoryPageStorage<telar::Memory>;
    extern template class HistoryPageStorage<telar::ConcurrentMemory>;
    extern template class HistoryPageStorage<telar::SystemAllocator>;

  }
}

// Interface: history/plain_text.cppm
export {
  namespace telar::gui {

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

// Interface: history/search.cppm
export {
  namespace telar::gui {

    struct HistorySearch {
      static constexpr std::size_t maximum_query_bytes = 128;

      std::string_view query;
      bool failed_only = false;

      [[nodiscard]] static HistorySearch parse(std::string_view text, bool failed_only) noexcept;
    };

  }
}

// Interface: history/browser.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    class HistoryBrowser {
    public:
      static constexpr auto page_entries = static_cast<std::uint16_t>(HistoryPageStorage<Memory>::maximum_entries);
      static constexpr std::size_t maximum_command_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t maximum_query_bytes = HistorySearch::maximum_query_bytes;
      static constexpr std::size_t maximum_output_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t maximum_requests = 128;
      static constexpr std::size_t maximum_error_bytes = 128;

      explicit HistoryBrowser(Memory& memory);

      ~HistoryBrowser() = default;
      HistoryBrowser(const HistoryBrowser&) = delete;
      HistoryBrowser& operator=(const HistoryBrowser&) = delete;
      HistoryBrowser(HistoryBrowser&&) = delete;
      HistoryBrowser& operator=(HistoryBrowser&&) = delete;

      [[nodiscard]] QueryHistory begin(QueryHistory query);

      [[nodiscard]] QueryHistory refresh(std::uint64_t request_id);

      [[nodiscard]] bool canPage(HistoryPage direction) const noexcept;

      [[nodiscard]] std::optional<QueryHistory> page(HistoryPage direction, std::uint64_t request_id);

      bool apply(const HistoryResults& message);

      [[nodiscard]] const HistoryRow<Memory>& entry(std::uint64_t id) const;

      [[nodiscard]] std::size_t entryIndex(std::uint64_t id) const;

      [[nodiscard]] std::string_view command(std::uint64_t id) const;

      [[nodiscard]] bool canSubmit() const noexcept;

      [[nodiscard]] std::string_view selectedCommand() const;

      [[nodiscard]] std::optional<QueryHistory> readCommand(std::uint64_t request_id);

      bool select(std::size_t index);

      void setInspecting(bool enabled);

      [[nodiscard]] std::optional<ReadHistoryOutput> readOutput(std::uint64_t request_id);

      bool apply(const HistoryOutput& message);

      [[nodiscard]] DeleteHistory erase(std::uint64_t id, std::uint64_t request_id);

      bool apply(const HistoryPruned& message);

      [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept;

      void setError(std::string_view message);

      bool fail(std::uint64_t request_id, std::string_view message);

      void suspend() noexcept;

      [[nodiscard]] const Vector<HistoryRow<Memory>, Memory>& rows() const noexcept;

      [[nodiscard]] const HistoryViewState& state() const noexcept;

      [[nodiscard]] std::string_view output() const noexcept;

      [[nodiscard]] std::string_view error() const noexcept;

      [[nodiscard]] std::uint64_t viewVersion() const noexcept;

      [[nodiscard]] std::uint64_t revision() const noexcept;

      [[nodiscard]] std::optional<HistoryChoice> choice() const noexcept;

      [[nodiscard]] bool acceptsRow(HistoryChoice candidate) const noexcept;

      [[nodiscard]] bool accepts(HistoryChoice candidate) const noexcept;

      [[nodiscard]] std::uint64_t rowsVersion() const noexcept;

      [[nodiscard]] HistoryScope scope() const noexcept;

      [[nodiscard]] HistoryMatch match() const noexcept;

      [[nodiscard]] bool deleting() const noexcept;

    private:
      // What a search asks for, without the text the stored strings hold.
      struct Criteria {
        HistoryScope scope{};
        std::optional<std::uint64_t> scope_id;
        bool scope_path = false;
        bool failed_only = false;
        HistoryAuthorFilter author{};
        HistoryMatch match{};
        bool distinct = false;
      };

      struct PageRequest {
        std::uint64_t request_id = 0;
        std::uint32_t offset = 0;
        std::uint64_t snapshot_id = 0;
      };

      void contentChanged() noexcept;

      QueryHistory prepareQuery(QueryHistory query);

      // The request views the stored query text and scope path.
      [[nodiscard]] QueryHistory request(PageRequest page) const noexcept;

      HistoryPageStorage<Memory> copyPage(std::span<const HistoryEntry> entries);

      bool applyCommand(std::span<const HistoryEntry> entries);

      void rejectQuery(std::string_view message);

      QueryHistory requestPage(PageRequest page);

      void track(std::uint64_t request_id);

      void retire(std::uint64_t request_id) noexcept;

      void clearCommand() noexcept;

      void clearOutput() noexcept;

      Memory& memory_;
      HistoryPageStorage<Memory> page_;
      String<Memory> selected_command_;
      String<Memory> query_;
      String<Memory> scope_path_;
      String<Memory> output_;
      runtime::FixedText<maximum_error_bytes> error_;
      Criteria criteria_;
      HistoryViewState state_;
      std::array<std::uint64_t, maximum_requests> requests_{};
      std::uint64_t page_request_ = 0;
      std::uint64_t command_request_ = 0;
      std::uint64_t output_request_ = 0;
      std::uint64_t delete_request_ = 0;
      std::uint64_t revision_ = 0;
      std::uint64_t view_version_ = 0;
      std::uint64_t rows_version_ = 0;
      std::uint32_t pending_offset_ = 0;
    };

    extern template class HistoryBrowser<telar::Memory>;
    extern template class HistoryBrowser<telar::ConcurrentMemory>;
    extern template class HistoryBrowser<telar::SystemAllocator>;

  }
}
