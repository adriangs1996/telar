module;

// The page of the history the panel shows and the requests that fill it. Nothing here is
// exported: only the feature's own units name it, through State.
export module telar.gui.features.history:browser;

import std;

import :entry;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.gui.foundation.core;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: history/page_storage.cppm
namespace telar::gui::features::history {

  template <Allocator Memory>
  class HistoryPageStorage {
  public:
    static constexpr std::size_t maximum_entries = HistoryLimits::page_entries;
    static constexpr std::size_t command_preview_bytes = HistoryLimits::command_preview_bytes;
    static constexpr std::size_t command_cache_bytes = HistoryLimits::command_cache_bytes;

    explicit HistoryPageStorage(tbc::mut_a<Memory> memory, std::span<const HistoryEntry> entries = {});

    void exchangeWith(HistoryPageStorage& other);

    [[nodiscard]] const ds::Vec<HistoryRow<Memory>, Memory>& rows() const noexcept;

    [[nodiscard]] std::string_view command(std::size_t index) const;

    // Row `index` leaves the page; a cached command it held stays in the cache, unread.
    void remove(std::size_t index);

  private:
    static std::size_t commandBytes(std::span<const HistoryEntry> entries);

    void append(tbc::mut_a<Memory> memory, const HistoryEntry& entry);

    tbc::val_a<ds::Vec<HistoryRow<Memory>, Memory>> rows_;
    tbc::val_a<ds::String<Memory>> commands_;
  };

  extern template class HistoryPageStorage<telar::Memory>;
  extern template class HistoryPageStorage<telar::ConcurrentMemory>;
  extern template class HistoryPageStorage<telar::SystemAllocator>;

}

// Interface: history/browser.cppm
namespace telar::gui::features::history {

  template <Allocator Memory>
  class HistoryBrowser {
  public:
    static constexpr auto page_entries = HistoryLimits::page_entries;
    static constexpr std::size_t maximum_command_bytes = HistoryLimits::maximum_command_bytes;
    static constexpr std::size_t maximum_query_bytes = HistoryLimits::maximum_query_bytes;
    static constexpr std::size_t maximum_output_bytes = HistoryLimits::maximum_output_bytes;
    static constexpr std::size_t maximum_requests = HistoryLimits::maximum_requests;
    static constexpr std::size_t maximum_error_bytes = HistoryLimits::maximum_error_bytes;

    explicit HistoryBrowser(Memory& memory);

    ~HistoryBrowser() = default;
    HistoryBrowser(const HistoryBrowser&) = delete;
    HistoryBrowser& operator=(const HistoryBrowser&) = delete;
    HistoryBrowser(HistoryBrowser&&) = delete;
    HistoryBrowser& operator=(HistoryBrowser&&) = delete;

    [[nodiscard]] QueryHistory begin(QueryHistory query);

    [[nodiscard]] ds::Option<QueryHistory> refresh(std::uint64_t request_id);

    [[nodiscard]] bool canPage(HistoryPage direction) const noexcept;

    [[nodiscard]] ds::Option<QueryHistory> page(HistoryPage direction, std::uint64_t request_id);

    bool apply(const HistoryResults& message);

    [[nodiscard]] const HistoryRow<Memory>& entry(std::uint64_t id) const;

    [[nodiscard]] std::size_t entryIndex(std::uint64_t id) const;

    [[nodiscard]] std::string_view command(std::uint64_t id) const;

    [[nodiscard]] bool canSubmit() const noexcept;

    [[nodiscard]] std::string_view selectedCommand() const;

    [[nodiscard]] ds::Option<QueryHistory> readCommand(std::uint64_t request_id);

    bool select(std::size_t index);

    void setInspecting(bool enabled);

    [[nodiscard]] ds::Option<ReadHistoryOutput> readOutput(std::uint64_t request_id);

    // How every run of the selected command went, and its runs in each of the days that end at
    // `until_ms`, while it is inspected.
    [[nodiscard]] ds::Option<QueryHistoryCommandStats> readRuns(std::uint64_t request_id, std::int64_t until_ms);

    // The runs around the selected one in its pane, while it is inspected.
    [[nodiscard]] ds::Option<QueryHistory> readContext(std::uint64_t request_id);

    [[nodiscard]] const HistoryRunStats& runStats() const noexcept;

    [[nodiscard]] std::size_t contextCount() const noexcept;

    [[nodiscard]] HistoryContextEntry contextAt(std::size_t index) const;

    bool apply(const HistoryOutput& message);

    bool apply(const HistoryCommandStats& message);

    [[nodiscard]] DeleteHistory erase(std::uint64_t id, std::uint64_t request_id);

    bool apply(const HistoryPruned& message);

    [[nodiscard]] ds::Option<DeleteHistory> hide(std::uint64_t id, std::uint64_t request_id);

    [[nodiscard]] ds::Option<DeleteHistory> commitHidden(std::uint64_t request_id);

    bool unhide() noexcept;

    [[nodiscard]] std::uint64_t hidden() const noexcept;

    [[nodiscard]] std::string_view hiddenCommand() const noexcept;

    bool toggleMark(std::uint64_t id);

    void clearMarks() noexcept;

    [[nodiscard]] std::size_t markCount() const noexcept;

    [[nodiscard]] std::uint64_t markedId(std::size_t index) const noexcept;

    [[nodiscard]] std::string_view markedCommand(std::size_t index) const;

    [[nodiscard]] bool marked(std::uint64_t id) const noexcept;

    [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept;

    void setError(std::string_view message);

    HistoryFailure fail(std::uint64_t request_id, std::string_view message);

    void suspend() noexcept;

    // Whether the panel follows the runtime's changes to the history: true when that changed.
    bool watch(bool watching) noexcept;

    [[nodiscard]] bool watching() const noexcept;

    // Whether a refresh asked while another was on its way is due now that it arrived; asked once.
    [[nodiscard]] bool takeRefreshDue() noexcept;

    [[nodiscard]] const ds::Vec<HistoryRow<Memory>, Memory>& rows() const noexcept;

    [[nodiscard]] const HistoryViewState& state() const noexcept;

    [[nodiscard]] std::string_view output() const noexcept;

    [[nodiscard]] std::string_view error() const noexcept;

    [[nodiscard]] std::uint64_t viewVersion() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    [[nodiscard]] ds::Option<HistoryChoice> choice() const noexcept;

    [[nodiscard]] bool acceptsRow(HistoryChoice candidate) const noexcept;

    [[nodiscard]] bool accepts(HistoryChoice candidate) const noexcept;

    [[nodiscard]] std::uint64_t rowsVersion() const noexcept;

    [[nodiscard]] HistoryScope scope() const noexcept;

    [[nodiscard]] HistoryMatch match() const noexcept;

    // Whether the pane scope reads the commands from before the pane started too.
    [[nodiscard]] bool preloads() const noexcept;

    // Whether the search reads what the commands printed.
    [[nodiscard]] bool searchesOutput() const noexcept;

    [[nodiscard]] bool deleting() const noexcept;

  private:
    // What a search asks for, without the text the stored strings hold.
    struct Criteria {
      HistoryScope scope{};
      ds::Option<std::uint64_t> scope_id;
      bool scope_path = false;
      bool failed_only = false;
      HistoryAuthorFilter author{};
      HistoryMatch match{};
      bool distinct = false;
      HistorySort sort{};
      std::int64_t since_ms = 0;
      std::int64_t until_ms = 0;
      ds::Option<std::int32_t> exit_code;
      std::uint64_t min_duration_ms = 0;
      std::uint64_t origin_pane = 0;
      std::uint8_t neighbours = 0;
      bool preload = false;
      bool output = false;
    };

    // Where a page begins: the matches before it, and, in a listing by time, the last run the
    // page before it showed, past which it reads. Paged by that run, a listing skips nothing a
    // delete took from an earlier page; an id of 0 pages by the offset alone.
    struct PageStart {
      std::uint32_t offset = 0;
      std::int64_t after_started_ms = 0;
      std::uint64_t after_id = 0;
    };

    struct PageRequest {
      std::uint64_t request_id = 0;
      PageStart start;
      std::uint64_t snapshot_id = 0;
      HistoryLoad load = HistoryLoad::search;
    };

    // The command a refreshed page keeps selected: the same command wherever it moved, else the
    // row at its index. An index past the page selects the last row.
    struct KeptSelection {
      std::uint64_t id = 0;
      std::size_t index = 0;
      HistoryStatus status = HistoryStatus::completed;
    };

    void contentChanged() noexcept;

    // Delete `request_id` is done with; false when it is none of the pending ones.
    bool forgetDelete(std::uint64_t request_id) noexcept;

    QueryHistory prepareQuery(QueryHistory query);

    // The request views the stored query text and scope path.
    [[nodiscard]] QueryHistory request(PageRequest page) const noexcept;

    HistoryPageStorage<Memory> copyPage(std::span<const HistoryEntry> entries);

    bool applyCommand(std::span<const HistoryEntry> entries);

    bool applyContext(std::span<const HistoryEntry> entries);

    // Keeps the commands around entry `inspected` of `entries`.
    void keepContext(std::span<const HistoryEntry> entries, std::size_t inspected);

    // The read of every run whose command starts with the selected one's, from which the context
    // keeps the runs around it; none when its text is not loaded or too long to ask with.
    [[nodiscard]] ds::Option<QueryHistory> sameCommand(std::uint64_t request_id) const;

    void rejectQuery(std::string_view message);

    // The rows leave the panel: they answered a search that is no longer the one shown.
    void clearRows();

    // Selects the row a refresh kept, and forgets the details of a command it no longer shows.
    void restoreSelection(KeptSelection kept);

    QueryHistory requestPage(PageRequest page);

    void track(std::uint64_t request_id);

    void retire(std::uint64_t request_id) noexcept;

    void clearCommand() noexcept;

    void clearOutput() noexcept;

    // Row `index` leaves the page, the selection moving to the row that takes its place.
    void removeRow(std::size_t index);

    struct Mark {
      std::uint64_t id = 0;
      std::size_t offset = 0;
      std::size_t length = 0;
    };

    struct ContextLine {
      std::size_t offset = 0;
      std::size_t length = 0;
      bool newer = false;
    };

    // The matches a page shows: a raw listing's runs around them are not counted.
    [[nodiscard]] std::uint32_t matchesShown() const noexcept;

    // Whether the runtime lists the search by time, which pages by the last run shown; a ranked
    // listing pages by offset. As the runtime decides: rank when asked, or for a fuzzy query when
    // left to it, and never for a search of the output.
    [[nodiscard]] bool listsByTime() const noexcept;

    // The page before the one shown: where the search entered this one from, else a page of
    // matches back.
    [[nodiscard]] PageStart newerStart() const noexcept;

    Memory& memory_;
    HistoryPageStorage<Memory> page_;
    ds::String<Memory> selected_command_;
    ds::String<Memory> query_;
    ds::String<Memory> scope_path_;
    ds::String<Memory> host_;
    ds::String<Memory> branch_;
    ds::String<Memory> shell_;
    ds::String<Memory> origin_cwd_;
    ds::String<Memory> output_;
    runtime::FixedText<maximum_error_bytes> error_;
    Criteria criteria_;
    HistoryViewState state_;
    ds::Array<std::uint64_t, maximum_requests> requests_{};
    std::uint64_t page_request_ = 0;
    std::uint64_t command_request_ = 0;
    std::uint64_t output_request_ = 0;
    std::uint64_t runs_request_ = 0;
    std::uint64_t context_request_ = 0;
    // The command the runs and the context are of, and what they hold.
    std::uint64_t runs_id_ = 0;
    std::uint64_t context_id_ = 0;
    HistoryRunStats run_stats_;
    ds::Array<ContextLine, 2 * HistoryLimits::context_entries> context_{};
    std::size_t context_count_ = 0;
    ds::String<Memory> context_text_;
    // Where each older page the search went to was entered from, newest last: a raw listing's
    // pages hold as many rows as matches cannot tell, and a listing by time reads past a run, so
    // going back reads where it came from.
    static constexpr std::size_t remembered_pages = 64;
    ds::Array<PageStart, remembered_pages> newer_starts_{};
    std::size_t newer_count_ = 0;
    // Where the page shown, and the one on its way, begin.
    PageStart page_start_;
    PageStart pending_start_;
    // The deletes the runtime has not confirmed, and the entries they delete, by slot: 0 is free.
    // Their rows left the page when they were sent, and no page that arrives brings them back.
    ds::Array<std::uint64_t, maximum_requests> delete_requests_{};
    ds::Array<std::uint64_t, maximum_requests> deleted_ids_{};
    // The command whose delete waits for its undo to pass, and the text its row showed; 0 is none.
    // Its row left the page, and no page that arrives brings it back.
    std::uint64_t hidden_id_ = 0;
    ds::String<Memory> hidden_command_;
    // The commands marked to be used together, in the order they were marked, and their text.
    ds::Array<Mark, HistoryLimits::maximum_marks> marks_{};
    std::size_t mark_count_ = 0;
    ds::String<Memory> marked_text_;
    std::uint64_t revision_ = 0;
    std::uint64_t view_version_ = 0;
    std::uint64_t rows_version_ = 0;
    bool watching_ = false;
    // A refresh was asked while one was on its way, which may have read the history before.
    bool refresh_again_ = false;
    bool refresh_due_ = false;
  };

  extern template class HistoryBrowser<telar::Memory>;
  extern template class HistoryBrowser<telar::ConcurrentMemory>;
  extern template class HistoryBrowser<telar::SystemAllocator>;

}
