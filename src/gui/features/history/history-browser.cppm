module;
#include "tbc/annotations.hpp"

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

    [[nodiscard]] QueryHistory refresh(std::uint64_t request_id);

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

    bool apply(const HistoryOutput& message);

    [[nodiscard]] DeleteHistory erase(std::uint64_t id, std::uint64_t request_id);

    bool apply(const HistoryPruned& message);

    [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept;

    void setError(std::string_view message);

    bool fail(std::uint64_t request_id, std::string_view message);

    void suspend() noexcept;

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
    ds::String<Memory> selected_command_;
    ds::String<Memory> query_;
    ds::String<Memory> scope_path_;
    ds::String<Memory> output_;
    runtime::FixedText<maximum_error_bytes> error_;
    Criteria criteria_;
    HistoryViewState state_;
    ds::Array<std::uint64_t, maximum_requests> requests_{};
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
