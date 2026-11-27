#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <new>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.gui.features.history;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::history;

  // The feature's use cases under the names the browser's methods had, so each assertion reads as
  // it did; every call goes through the feature's boundary, its reads through HistoryView.
  class Browser {
  public:
    static constexpr auto page_entries = HistoryLimits::page_entries;
    static constexpr auto maximum_requests = HistoryLimits::maximum_requests;
    static constexpr auto maximum_command_bytes = HistoryLimits::maximum_command_bytes;
    static constexpr auto maximum_output_bytes = HistoryLimits::maximum_output_bytes;

    explicit Browser(telar::Memory& memory)
        : history_(memory) {}

    Browser(const Browser&) = delete;
    Browser& operator=(const Browser&) = delete;
    Browser(Browser&&) = delete;
    Browser& operator=(Browser&&) = delete;
    ~Browser() = default;

    [[nodiscard]] HistoryView reads() const noexcept {
      return view(history_);
    }

    QueryHistory begin(QueryHistory query) {
      return search(history_, query);
    }

    ds::Option<QueryHistory> page(HistoryPage direction, std::uint64_t request_id) {
      return features::history::page(history_, direction, request_id);
    }

    QueryHistory refresh(std::uint64_t request_id) {
      const auto request = features::history::refresh(history_, request_id);
      if (!request) {
        throw std::runtime_error{"the page could not be refreshed"};
      }

      return *request;
    }

    template <typename Message>
    bool apply(const Message& message) {
      return receive(history_, message);
    }

    bool select(std::size_t index) {
      return features::history::select(history_, index);
    }

    void setInspecting(bool enabled) {
      inspect(history_, enabled);
    }

    ds::Option<QueryHistory> readCommand(std::uint64_t request_id) {
      return features::history::readCommand(history_, request_id);
    }

    ds::Option<ReadHistoryOutput> readOutput(std::uint64_t request_id) {
      return features::history::readOutput(history_, request_id);
    }

    DeleteHistory erase(std::uint64_t id, std::uint64_t request_id) {
      return features::history::erase(history_, id, request_id);
    }

    bool fail(std::uint64_t request_id, std::string_view message) {
      return features::history::fail(history_, request_id, message) != HistoryFailure::none;
    }

    void suspend() noexcept {
      features::history::suspend(history_);
    }

    ds::Option<DeleteHistory> hide(std::uint64_t id, std::uint64_t request_id) {
      return features::history::hide(history_, id, request_id);
    }

    ds::Option<DeleteHistory> commitHidden(std::uint64_t request_id) {
      return features::history::commitHidden(history_, request_id);
    }

    bool unhide() noexcept {
      return features::history::unhide(history_);
    }

    bool toggleMark(std::uint64_t id) {
      return features::history::toggleMark(history_, id);
    }

    ds::Option<QueryHistoryCommandStats> readRuns(std::uint64_t request_id, CalendarSample sampled = {}) {
      return features::history::readRuns(history_, request_id, sampled);
    }

    ds::Option<QueryHistory> readContext(std::uint64_t request_id) {
      return features::history::readContext(history_, request_id);
    }

    bool watch(bool watching) noexcept {
      return features::history::watch(history_, watching);
    }

  private:
    State history_;
  };

  void ownedSearchAndPages() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    std::string query = "compiler errors";
    std::string directory = "/work/project";
    const auto started = browser.begin({.request_id = 1, .query = query, .scope = HistoryScope::cwd, .scope_value = std::string_view{directory}, .author = HistoryAuthorFilter::human, .match = HistoryMatch::fuzzy});

    query.assign("reused query storage");
    directory.assign("/reused/directory");
    check(started.query == "compiler errors" && std::get<std::string_view>(started.scope_value) == "/work/project", "query plans must own borrowed query and scope bytes");
    check(started.limit == decltype(browser)::page_entries && started.offset == 0 && started.snapshot_id == 0, "new searches must begin at an unbounded first page");

    const ds::Array first{HistoryEntry{.id = 1, .pane_id = 1, .command = "first"}, HistoryEntry{.id = 2, .pane_id = 1, .command = "second"}};

    check(browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 4, .has_more = true, .entries = first}), "the active page must commit");
    const auto older = browser.page(HistoryPage::older, 2);

    check(older && older->offset == first.size() && older->snapshot_id == 4 && older->query == "compiler errors", "older pages must retain the insertion boundary and search filters");
    check(browser.reads().rows().size() == first.size() && browser.reads().state().phase == HistoryPhase::loading, "pending pages must retain their visible rows");
    check(!browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 4, .entries = first}), "late page replies must not unlock a newer request");

    const ds::Array second{HistoryEntry{.id = 3, .pane_id = 1, .command = "older"}};

    check(browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 4, .entries = second}), "the older page must replace the previous rows");
    check(!browser.reads().canPage(HistoryPage::older) && browser.reads().canPage(HistoryPage::newer), "page controls must reflect the actual page boundary");
    const auto newer = browser.page(HistoryPage::newer, 3);

    check(newer && newer->offset == 0 && newer->snapshot_id == 4, "newer paging must saturate at the first page");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 4, .has_more = true, .entries = first});
    check(browser.reads().state().selection == first.size() - 1, "returning to a newer page must select its last row");
    const auto refreshed = browser.refresh(4);

    check(refreshed.offset == 0 && refreshed.snapshot_id == 0, "a refresh must choose a new insertion boundary");
  }

  // After a delete the list stays on its page, with the selection on the row that took the
  // deleted one's place, or the last when the deleted one was last.
  void deleteKeepsThePosition() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};
    const ds::Array second{HistoryEntry{.id = 3, .command = "c"}, HistoryEntry{.id = 4, .command = "d"}, HistoryEntry{.id = 5, .command = "e"}};
    const ds::Array after{HistoryEntry{.id = 3, .command = "c"}, HistoryEntry{.id = 5, .command = "e"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 7, .has_more = true, .entries = first});
    static_cast<void>(browser.page(HistoryPage::older, 2));
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 7, .entries = second});
    browser.select(1);
    static_cast<void>(browser.erase(4, 3));
    browser.apply(HistoryPruned{.request_id = 3, .removed = 1});
    const auto refreshed = browser.refresh(4);

    check(refreshed.offset == first.size() && refreshed.snapshot_id == 0, "the refresh reads the same page anew");
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 8, .entries = after});
    check(browser.reads().state().page_offset == first.size() && browser.reads().state().selection == 1, "the selection stays on the next row");
    browser.select(1);
    static_cast<void>(browser.erase(5, 5));
    browser.apply(HistoryPruned{.request_id = 5, .removed = 1});
    static_cast<void>(browser.refresh(6));
    browser.apply(HistoryResults{.request_id = 6, .snapshot_id = 9, .entries = std::span{after}.first(1)});
    check(browser.reads().state().selection == 0, "the last row deleted selects the one before it");

    // The only row of a later page deleted: the page before it, at its last row.
    static_cast<void>(browser.erase(3, 7));
    browser.apply(HistoryPruned{.request_id = 7, .removed = 1});
    const auto back = browser.refresh(8);

    check(back.offset == 0, "an emptied page gives way to the one before it");
    browser.apply(HistoryResults{.request_id = 8, .snapshot_id = 10, .entries = first});
    check(browser.reads().state().page_offset == 0 && browser.reads().state().selection == first.size() - 1, "at its last row");
  }

  // Deletes queue: a second before the first is confirmed goes too, and no page that arrives
  // meanwhile brings a deleted row back.
  void deletesQueue() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array entries{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}, HistoryEntry{.id = 3, .command = "c"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = entries});
    const auto first = browser.erase(1, 2);
    const auto second = browser.erase(2, 3);

    check(browser.reads().rows().size() == 1 && browser.reads().rows().front().id == 3, "both rows leave at once");
    check(browser.apply(HistoryPruned{.request_id = first.request_id, .removed = 1}) && browser.reads().deleting(), "the first confirmation leaves the second waiting");
    static_cast<void>(browser.refresh(4));
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 2, .entries = std::span{entries}.last(2)});
    check(browser.reads().rows().size() == 1 && browser.reads().rows().front().id == 3, "a page read before the second delete does not bring its row back");
    check(browser.apply(HistoryPruned{.request_id = second.request_id, .removed = 1}) && !browser.reads().deleting(), "the second confirmation ends the deletes");
  }

  // A detail that failed is read again for the same row, and one that does not fit the request
  // table fails alone, never the page.
  void detailsRetryAndFailAlone() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array entries{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};
    std::uint64_t sequence = 0;

    static_cast<void>(browser.begin({.request_id = ++sequence}));
    browser.apply(HistoryResults{.request_id = sequence, .snapshot_id = 1, .entries = entries});
    browser.setInspecting(true);
    const auto first = browser.readOutput(++sequence);

    check(first.hasValue(), "inspecting reads the output");
    browser.fail(first->request_id, "output failed");
    const auto again = browser.readOutput(++sequence);

    check(again && again->id == first->id, "a failed output is read again for the same row");

    // Searches that never answered fill the table; the last one's page arrives, and a delete
    // takes the slot its answer freed.
    while (sequence < decltype(browser)::maximum_requests + 2) {
      static_cast<void>(browser.begin({.request_id = ++sequence}));
    }

    browser.apply(HistoryResults{.request_id = sequence, .snapshot_id = 2, .entries = entries});
    static_cast<void>(browser.erase(1, ++sequence));
    browser.setInspecting(false);
    browser.setInspecting(true);
    bool refused = false;

    try {
      static_cast<void>(browser.readOutput(++sequence));
    } catch (const std::exception&) {
      refused = true;
    }

    check(refused && browser.reads().state().output_phase == HistoryPhase::failed, "the output that does not fit fails");
    check(browser.reads().state().phase == HistoryPhase::ready, "the page it was for stays");
  }

  void renderedChoicesNeverRetargetACommand() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};

    check(!browser.reads().choice(), "an idle browser must not offer a command choice");
    const ds::Array entries{HistoryEntry{.id = 1, .command = "first"}, HistoryEntry{.id = 2, .command = "second"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = entries});
    const auto presented = browser.reads().choice();
    if (!presented) {
      throw std::runtime_error{"a ready page must provide a selected choice"};
    }

    check(browser.reads().accepts(*presented), "a ready page must accept its selected choice");
    check(!browser.reads().acceptsRow({.index = entries.size(), .revision = browser.reads().revision()}), "a choice outside the page must be rejected");
    const auto previous_view = browser.reads().viewVersion();

    browser.select(1);
    check(!browser.reads().accepts(*presented), "selection must not retarget a previously drawn submit action");
    check(browser.reads().acceptsRow(*presented), "selection must preserve row choices from the same page");
    check(browser.reads().revision() == presented->revision && browser.reads().viewVersion() > previous_view, "selection must publish view changes without invalidating the content revision");
    browser.select(0);
    check(browser.reads().accepts(*presented), "returning to the selected row on the same page must retain the original submission guard");
    browser.setInspecting(true);
    check(browser.reads().acceptsRow(*presented), "opening inspection must preserve ready row choices until a detail request changes the content");
    const auto selected = browser.reads().choice();
    if (!selected) {
      throw std::runtime_error{"the new selection must provide its own choice"};
    }

    check(browser.reads().accepts(*selected), "the new selection must accept its own choice");
    static_cast<void>(browser.page(HistoryPage::older, 2));
    check(!browser.reads().choice() && !browser.reads().acceptsRow(*selected), "loading must disable the old choice while retaining its visible rows");
    check(browser.reads().rows().size() == entries.size(), "the pending page must preserve displayed rows");
    const ds::Array replacement{HistoryEntry{.id = 3, .command = "replacement"}};

    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 1, .entries = replacement});
    check(!browser.reads().acceptsRow(*selected), "a completed page must not reuse a previous row index as a command choice");
    const auto replaced = browser.reads().choice();
    if (!replaced) {
      throw std::runtime_error{"the replacement must provide its own choice"};
    }

    check(browser.reads().rows()[replaced->index].id == replacement.front().id, "the replacement must select its own command");
    static_cast<void>(browser.begin({.request_id = 3}));
    browser.fail(3, "search failed");
    check(!browser.reads().choice() && !browser.reads().accepts(*replaced), "a failed search must not restore the previous choice");
    static_cast<void>(browser.begin({.request_id = 4}));
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 2});
    check(!browser.reads().choice(), "an empty ready page must not offer a command choice");
    browser.suspend();
    check(!browser.reads().accepts(*replaced), "disconnect must invalidate a drawn choice");
  }

  void boundedRequestsAndStaleFailures() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    std::uint64_t sequence = 0;

    for (std::size_t index = 0; index < decltype(browser)::maximum_requests; ++index) {
      static_cast<void>(browser.begin({.request_id = ++sequence}));
    }

    bool rejected = false;

    try {
      static_cast<void>(browser.begin({.request_id = ++sequence}));
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && browser.reads().state().phase == HistoryPhase::failed, "request saturation must block submission without growing storage");
    check(browser.reads().owns(1) && !browser.fail(1, "stale failure"), "an obsolete failure must retire its request without replacing the current error");
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    check(browser.reads().state().phase == HistoryPhase::loading, "retiring a stale request must restore bounded request capacity");
    browser.suspend();
    check(!browser.reads().owns(sequence) && browser.reads().state().phase == HistoryPhase::idle, "disconnect must invalidate every history request");
  }

  void allocationFailureIsAtomic() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{4} * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};

    {
      Browser browser{adapter};

      static_cast<void>(browser.begin({.request_id = 1}));
      const ds::Array initial{HistoryEntry{.id = 1, .pane_id = 1, .command = "retained"}};

      browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = initial});
      static_cast<void>(browser.begin({.request_id = 2}));
      const auto live_bytes = budget.liveBytes();
      const std::string large_command(decltype(browser)::maximum_output_bytes, 'x');
      const ds::Array replacement{HistoryEntry{.id = 2, .pane_id = 1, .command = large_command}};
      bool rejected = false;

      try {
        browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 2, .entries = replacement});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      check(rejected && browser.reads().state().phase == HistoryPhase::failed, "allocation failure must close input authority");
      check(browser.reads().rows().empty(), "a search whose page could not be stored shows no rows of the search before it");
      check(budget.liveBytes() <= live_bytes, "failed page staging must release every temporary allocation");
      static_cast<void>(browser.begin({.request_id = 3}));
      browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 3, .entries = initial});
      check(browser.reads().command(1) == "retained", "a later successful query must restore submission authority");
    }

    check(budget.liveBytes() == 0 && budget.failures() != 0, "history ownership must release all injected storage after a tested failure");
  }

  void inspectionAllocationFailure() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{4} * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};

    {
      Browser browser{adapter};

      static_cast<void>(browser.begin({.request_id = 1}));
      const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "available"}};

      browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = entries});
      browser.setInspecting(true);
      const auto request = browser.readOutput(2);
      if (!request) {
        throw std::runtime_error{"Inspection must produce a request"};
      }

      const std::string large_output(decltype(browser)::maximum_output_bytes, 'x');
      bool rejected = false;

      try {
        browser.apply(HistoryOutput{.request_id = request->request_id, .id = 1, .content = byteView(large_output)});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      check(rejected && browser.reads().state().output_phase == HistoryPhase::failed && !browser.reads().error().empty(), "inspection allocation failure must replace its loading indicator with a bounded error");
      check(browser.reads().state().phase == HistoryPhase::ready && browser.reads().command(1) == "available", "inspection failure must preserve the current command page and input authority");
      browser.setInspecting(false);
      browser.setInspecting(true);
      static_cast<void>(browser.readOutput(3));
      browser.apply(HistoryOutput{.request_id = 3, .id = 1, .content = byteView("recovered")});
      check(browser.reads().output() == "recovered" && browser.reads().error().empty(), "a later successful inspection must clear its previous error");
    }

    check(budget.liveBytes() == 0, "failed inspections must release every injected allocation");
  }

  void inspectionAndDeletion() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    std::uint64_t sequence = 0;
    const auto query = browser.begin({.request_id = ++sequence});
    const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "first"}, HistoryEntry{.id = 2, .pane_id = 1, .command = "second"}};

    browser.apply(HistoryResults{.request_id = query.request_id, .snapshot_id = 1, .entries = entries});
    browser.setInspecting(true);
    const auto first = browser.readOutput(++sequence);
    if (!first) {
      throw std::runtime_error{"The selected command must produce an inspection request"};
    }

    check(first->id == 1 && !browser.readOutput(++sequence), "inspection must issue one read for the selected command");
    browser.select(1);
    const auto second = browser.readOutput(++sequence);
    if (!second) {
      throw std::runtime_error{"A new selection must produce its own inspection request"};
    }

    check(second->id == 2, "changing selection must request the newly selected command");
    check(!browser.apply(HistoryOutput{.request_id = first->request_id, .id = 1, .content = byteView("stale")}), "late output must not replace a newer inspection");
    const auto rows_version = browser.reads().rowsVersion();
    std::string output = "\x1b[31mred\x1b[0m\r\n\x1b]2;hidden\aend";

    browser.apply(HistoryOutput{.request_id = second->request_id, .id = 2, .truncated = true, .observed_bytes = output.size(), .content = byteView(output)});
    output.assign("reused network storage");
    check(browser.reads().output() == "red\nend" && browser.reads().state().output_truncated, "inspection must own sanitized output and preserve truncation status");
    check(browser.reads().rowsVersion() == rows_version, "inspection changes must not invalidate projected command rows");

    const auto deletion = browser.erase(2, ++sequence);

    check(browser.reads().rows().size() == 1 && browser.reads().rows().front().id == 1 && browser.reads().deleting(), "a deleted row leaves the list at once");
    check(browser.reads().state().selection == 0, "the selection moves to a row still there");
    check(browser.apply(HistoryPruned{.request_id = deletion.request_id, .removed = 1}), "only the matching deletion confirmation may trigger refresh");
    const auto stale_deletion = browser.erase(1, ++sequence);

    static_cast<void>(browser.begin({.request_id = ++sequence, .query = "new filter"}));
    check(!browser.apply(HistoryPruned{.request_id = stale_deletion.request_id, .removed = 1}), "an old deletion must not refresh a newer search generation");
  }

  void boundedCommandsAndSelectedReads() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{1024} * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};

    {
      Browser browser{adapter};
      std::uint64_t sequence = 0;
      using Storage = HistoryLimits;
      constexpr auto command_bytes = decltype(browser)::maximum_command_bytes;
      constexpr auto first_uncached = Storage::command_cache_bytes / command_bytes;
      const std::string large_command(command_bytes, 'x');
      ds::Array<HistoryEntry, decltype(browser)::page_entries> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        entries.atMut(index) = {.id = index + 1, .pane_id = 1, .command = large_command};
      }

      static_cast<void>(browser.begin({.request_id = ++sequence}));
      browser.apply(HistoryResults{.request_id = sequence, .snapshot_id = 1, .entries = entries});
      check(budget.failures() == 0 && budget.liveBytes() < allocation_budget, "a page of maximal commands must fit its bounded cache and previews");
      check(browser.reads().rows().front().command.size() == Storage::command_preview_bytes && browser.reads().command(1) == large_command, "bounded previews must retain complete cached commands for input");
      check(browser.reads().rows()[first_uncached - 1].command_complete && !browser.reads().rows()[first_uncached].command_complete, "the shared command budget must admit only complete commands");
      browser.select(first_uncached);
      check(!browser.reads().canSubmit(), "uncached previews must never authorize input");
      check(browser.reads().selectedCommand() == browser.reads().rows()[first_uncached].command, "an uncached selection must display only its owned preview");
      const auto request = browser.readCommand(++sequence);
      if (!request) {
        throw std::runtime_error{"An uncached selection must request its complete command"};
      }

      check(request->entry_id == first_uncached + 1 && request->limit == 1 && !browser.readCommand(++sequence), "full reads must query one canonical identity without duplicates");
      browser.select(first_uncached + 1);
      const auto current = browser.readCommand(++sequence);
      if (!current) {
        throw std::runtime_error{"The new uncached selection must own its read"};
      }

      check(!browser.apply(HistoryResults{.request_id = request->request_id, .entries = std::span{entries}.subspan(first_uncached, 1)}), "a late full command must not replace the current selection");
      const auto rows_version = browser.reads().rowsVersion();

      browser.apply(HistoryResults{.request_id = current->request_id, .entries = std::span{entries}.subspan(first_uncached + 1, 1)});
      check(browser.reads().canSubmit() && browser.reads().command(current->entry_id) == large_command, "only a complete matching reply may authorize the selected command");
      check(browser.reads().selectedCommand() == large_command, "inspection must expose the complete selected command after its matching read");
      check(browser.reads().rowsVersion() == rows_version && budget.failures() == 0, "selected detail must not rebuild the page or exceed its memory budget");
      static_cast<void>(browser.begin({.request_id = ++sequence}));
      check(!browser.reads().canSubmit() && browser.reads().state().command_phase == HistoryPhase::idle, "a new search must invalidate selected command ownership");
    }

    check(budget.liveBytes() == 0, "bounded command storage must release all injected memory");
  }

  void selectedCommandFailures() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    std::uint64_t sequence = 0;
    using Storage = HistoryLimits;
    constexpr auto command_bytes = decltype(browser)::maximum_command_bytes;
    constexpr auto cached_entries = Storage::command_cache_bytes / command_bytes;
    const std::string large_command(command_bytes, 'x');
    ds::Array<HistoryEntry, cached_entries + 2> entries{};

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries.atMut(index) = {.id = index + 1, .pane_id = 1, .command = large_command};
    }

    entries.atMut(entries.size() - 1).command_truncated = true;
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    browser.apply(HistoryResults{.request_id = sequence, .entries = entries});
    browser.select(entries.size() - 1);
    check(!browser.reads().canSubmit() && !browser.readCommand(++sequence), "capture truncation must not be confused with a missing cached command");

    browser.select(cached_entries);
    static_cast<void>(browser.readCommand(++sequence));
    browser.apply(HistoryResults{.request_id = sequence, .entries = std::span{entries}.first(1)});
    check(!browser.reads().canSubmit() && browser.reads().state().command_phase == HistoryPhase::failed && browser.reads().state().phase == HistoryPhase::ready, "mismatched entry identity must fail locally without replacing the page");
    check(!browser.readCommand(++sequence), "a failed full read must not cause an automatic retry loop");
    browser.select(0);
    browser.select(cached_entries);
    static_cast<void>(browser.readCommand(++sequence));
    check(browser.fail(sequence, "Entry disappeared") && !browser.reads().canSubmit() && browser.reads().state().phase == HistoryPhase::ready, "full-read request failure must remain local to its selection");
    browser.select(0);
    browser.select(cached_entries);
    const auto obsolete_request = ++sequence;

    static_cast<void>(browser.readCommand(obsolete_request));
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    check(!browser.apply(HistoryResults{.request_id = obsolete_request, .entries = std::span{entries}.subspan(cached_entries, 1)}), "an obsolete full reply must not end a newer search");
    check(browser.reads().state().phase == HistoryPhase::loading && browser.reads().state().command_phase == HistoryPhase::idle, "query and selected-command phases must remain independent");
  }

  void commandPreviewBoundaries() {
    SystemAllocator memory;
    using Storage = HistoryLimits;
    std::string command(Storage::command_preview_bytes - 1, 'x');

    command += "🌱tail";
    const ds::Array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = command}};
    telar::MemoryAdapter adapted{memory};
    Browser page{adapted};

    static_cast<void>(page.begin({.request_id = 1}));
    page.apply(HistoryResults{.request_id = 1, .entries = entries});
    check(page.reads().rows().front().command.size() == Storage::command_preview_bytes - 1, "previews must stop before a split UTF-8 scalar");
    check(page.reads().command(1) == command, "preview truncation must preserve complete canonical command bytes");
  }

  void selectedCommandAllocationFailure() {
    SystemAllocator system;
    using Storage = HistoryLimits;
    constexpr auto command_bytes = Browser::maximum_command_bytes;
    constexpr auto cached_entries = Storage::command_cache_bytes / command_bytes;
    constexpr auto allocation_budget = Storage::command_cache_bytes + (command_bytes / 2);
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};

    {
      Browser browser{adapter};
      const std::string command(command_bytes, 'x');
      ds::Array<HistoryEntry, cached_entries + 1> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        entries.atMut(index) = {.id = index + 1, .pane_id = 1, .command = command};
      }

      static_cast<void>(browser.begin({.request_id = 1}));
      browser.apply(HistoryResults{.request_id = 1, .entries = entries});
      check(budget.failures() == 0, "the page fixture must fit before selected-detail allocation");
      browser.select(cached_entries);
      static_cast<void>(browser.readCommand(2));
      const auto live_bytes = budget.liveBytes();
      bool rejected = false;

      try {
        browser.apply(HistoryResults{.request_id = 2, .entries = std::span{entries}.last(1)});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      check(rejected && browser.reads().state().command_phase == HistoryPhase::failed && !browser.reads().canSubmit(), "a detail allocation failure must end loading without authorizing a preview");
      check(browser.reads().state().phase == HistoryPhase::ready && budget.liveBytes() == live_bytes && !browser.reads().owns(2), "detail allocation failure must retain page ownership and retire its request");
      browser.select(0);
      check(browser.reads().canSubmit() && browser.reads().command(1) == command, "a cached command must remain available after detail allocation failure");
    }

    check(budget.liveBytes() == 0 && budget.failures() != 0, "detail failure must release all injected memory");
  }

  void plainTextFixtures() {
    struct Example {
      std::string_view input;
      std::string_view expected;
    };

    constexpr auto examples = ds::Array<Example, 8>{
        Example{.input = "\x1b[31mfail\x1b[0m\r\n", .expected = "fail\n"},
        Example{.input = "before\x1b]52;c;hidden\aafter", .expected = "beforeafter"},
        Example{.input = "a\x1bPpayload\x1b\\b\x1bXhidden\x1b\\c\x1b^private\ad\x1b_graphics\x1b\\e", .expected = "abcde"},
        Example{.input = "a\x1b(Bb\x1b[12;", .expected = "ab"},
        Example{.input = "café\t🌱\n", .expected = "café\t🌱\n"},
        // A progress line rewritten with carriage returns shows its last state.
        Example{.input = "10%\r50%\r100%\ndone\n", .expected = "100%\ndone\n"},
        Example{.input = "first\nloading…\r\x1b[2Kready\r\n", .expected = "first\nready\n"},
        Example{.input = "end\r", .expected = "end"},
    };

    constexpr std::size_t output_capacity = 128;
    ds::Array<char, output_capacity> output{};

    for (const auto& example : examples) {
      const auto written = PlainText::strip(byteView(example.input), output.viewMut());

      check(std::string_view{output.data(), written} == example.expected, "terminal control stripping must match the original scanner fixtures");
    }

    constexpr std::size_t bounded_capacity = 3;
    const auto written = PlainText::strip(byteView("abcdef"), output.viewMut().first(bounded_capacity));

    check(std::string_view{output.data(), written} == "abc" && PlainText::strip(byteView("text"), {}) == 0, "plain text output must respect empty and bounded destinations");
  }

  // A refresh reads the page anew under the person's hands: the rows stay usable while it loads,
  // and the selection stays on the same command wherever the new page puts it.
  void refreshKeepsTheSelectedCommand() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}, HistoryEntry{.id = 3, .command = "c"}};
    const ds::Array newer{HistoryEntry{.id = 4, .command = "d"}, HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}, HistoryEntry{.id = 3, .command = "c"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = first});
    browser.select(2);
    static_cast<void>(browser.refresh(2));
    check(browser.reads().state().phase == HistoryPhase::ready && browser.reads().choice() && browser.reads().canSubmit(), "the rows stay usable while a refresh loads");
    check(browser.reads().command(3) == "c", "a command shown can be read while a refresh loads");
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 2, .entries = newer});
    check(browser.reads().rows()[browser.reads().state().selection].id == 3, "the selection follows its command to its new place");

    // A row chosen while the refresh loads is the one it keeps.
    static_cast<void>(browser.refresh(3));
    check(browser.select(1), "a row can be selected while a refresh loads");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 3, .entries = first});
    check(browser.reads().state().selection == 0 && browser.reads().rows().front().id == 1, "the row chosen while the refresh loaded stays selected");
  }

  // The inspector keeps showing the output of the command a refresh keeps selected.
  void refreshKeepsTheInspectedOutput() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};
    const ds::Array newer{HistoryEntry{.id = 3, .command = "c"}, HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = first});
    browser.setInspecting(true);
    const auto read = browser.readOutput(2);

    check(read.hasValue(), "inspecting reads the output");
    browser.apply(HistoryOutput{.request_id = 2, .id = 1, .content = byteView("built")});
    static_cast<void>(browser.refresh(3));
    check(browser.reads().output() == "built", "the output stays while a refresh loads");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 2, .entries = newer});
    check(browser.reads().output() == "built" && browser.reads().state().output_phase == HistoryPhase::ready, "the output stays once the refreshed page arrives");
    check(!browser.readOutput(4), "the output kept is not read again");
  }

  // A search that fails takes away the rows of the query before it, which would show under the
  // new query with its matches highlighted in them; a page that fails leaves the page shown.
  void failedSearchLeavesNoRowsOfTheQueryBefore() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "make"}, HistoryEntry{.id = 2, .command = "ls"}};

    static_cast<void>(browser.begin({.request_id = 1, .query = "m"}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = first});
    static_cast<void>(browser.page(HistoryPage::older, 2));
    browser.fail(2, "page failed");
    check(browser.reads().rows().size() == first.size() && browser.reads().state().phase == HistoryPhase::ready, "a failed page leaves the page shown usable");

    static_cast<void>(browser.begin({.request_id = 3, .query = "x"}));
    browser.fail(3, "search failed");
    check(browser.reads().rows().empty() && browser.reads().state().phase == HistoryPhase::failed && browser.reads().error() == "search failed", "a failed search shows no rows of the query before it");
  }

  // A new search typed while a later page shows selects its best match, never its last row.
  void searchFromALaterPageSelectsTheBestMatch() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = first});
    static_cast<void>(browser.page(HistoryPage::older, 2));
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 1, .entries = first});
    static_cast<void>(browser.begin({.request_id = 3, .query = "b"}));
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 2, .entries = first});
    check(browser.reads().state().selection == 0, "the new search selects its first row");
  }

  // A delete waits for its undo: its row leaves at once and no page brings it back, undo takes it
  // back, and a second delete sends the first.
  void deletesWaitForTheirUndo() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array entries{HistoryEntry{.id = 1, .command = "rm -rf build"}, HistoryEntry{.id = 2, .command = "make"}, HistoryEntry{.id = 3, .command = "ls"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = entries});
    check(!browser.hide(1, 2).hasValue(), "nothing waited before the first delete");
    check(browser.reads().rows().size() == 2 && browser.reads().hidden() == 1 && browser.reads().hiddenCommand() == "rm -rf build", "the row leaves and the notice names it");
    static_cast<void>(browser.refresh(3));
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 2, .entries = entries});
    check(browser.reads().rows().size() == 2, "a page read meanwhile does not bring it back");

    check(browser.unhide() && browser.reads().hidden() == 0, "undo takes the delete back");
    static_cast<void>(browser.refresh(4));
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 3, .entries = entries});
    check(browser.reads().rows().size() == entries.size(), "and the page read anew shows the row again");

    static_cast<void>(browser.hide(1, 5));
    const auto first = browser.hide(2, 6);

    check(first && first->id == 1 && first->request_id == 6, "a second delete sends the first");
    check(browser.reads().hidden() == 2 && browser.reads().deleting(), "the second waits for its own undo");
    const auto second = browser.commitHidden(7);

    check(second && second->id == 2 && browser.reads().hidden() == 0 && !browser.commitHidden(8), "the delete that waited goes once");
  }

  // Marked commands keep the order they were marked in, whatever the query shows after.
  void marksKeepTheirOrderAcrossSearches() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "make"}, HistoryEntry{.id = 2, .command = "make test"}};
    const ds::Array second{HistoryEntry{.id = 3, .command = "git push"}};

    static_cast<void>(browser.begin({.request_id = 1, .query = "make"}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = first});
    check(browser.toggleMark(2) && browser.toggleMark(1), "rows are marked");
    static_cast<void>(browser.begin({.request_id = 2, .query = "git"}));
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 1, .entries = second});
    check(browser.toggleMark(3), "a row of another search is marked too");
    check(browser.reads().markCount() == 3 && browser.reads().markedCommand(0) == "make test" && browser.reads().markedCommand(1) == "make" && browser.reads().markedCommand(2) == "git push", "the marks keep the order they were made in and their text");
    check(!browser.toggleMark(3) && browser.reads().markCount() == 2 && !browser.reads().marked(3), "marking again unmarks");

    const ds::Array truncated{HistoryEntry{.id = 4, .command = "partial", .command_truncated = true}};
    bool refused = false;

    static_cast<void>(browser.begin({.request_id = 3}));
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 1, .entries = truncated});
    try {
      static_cast<void>(browser.toggleMark(4));
    } catch (const EncodingError&) {
      refused = true;
    }

    check(refused && browser.reads().markCount() == 2, "a command whose capture was cut cannot be marked");
  }

  void historyPanelPreservesTheSearchPosition() {
    const HistoryModalMetrics metrics{.viewport = {.width = 1200, .height = 800}, .cell_height = 20};
    const auto browsing = HistoryModalGeometry::measure(metrics, false);
    const auto inspecting = HistoryModalGeometry::measure(metrics, true);
    constexpr Rect expected_bounds{.x = 28, .y = 94, .width = 1144, .height = 640};
    constexpr Rect expected_search{.x = 28, .y = 646, .width = 1144, .height = 52};

    check(browsing.bounds == expected_bounds && browsing.search == expected_search, "history must sit above the status bar with its search field at the foot");
    check(inspecting.bounds == browsing.bounds && inspecting.search == browsing.search && inspecting.footer == browsing.footer, "opening details must preserve the panel and input geometry");
    check(inspecting.results.right() == inspecting.inspection.x && inspecting.inspection.right() == browsing.results.right(), "a wide inspector must share the existing results rectangle");
  }

  void historyInspectionReplacesOnlyTheNarrowList() {
    const HistoryModalMetrics metrics{.viewport = {.width = 955, .height = 800}, .cell_height = 20};
    const auto narrow = HistoryModalGeometry::measure(metrics, true);

    check(narrow.bounds.width == HistoryModalGeometry::split_width - 1 && narrow.results.width == 0 && narrow.inspection.width == narrow.bounds.width, "a panel below the split threshold must give the list's space to details");
    auto wider = metrics;

    ++wider.viewport.width;
    const auto split = HistoryModalGeometry::measure(wider, true);

    check(split.bounds.width == HistoryModalGeometry::split_width && split.results.width > 0, "the exact split threshold must keep both views");
    check(split.inspectionContent(metrics.chrome).bottom() <= split.inspectionActions(metrics.chrome).y, "inspector text must not cover its action controls");
  }

  void historyCompactWindowsKeepNonnegativeBands() {
    const HistoryModalMetrics metrics{.viewport = {.width = 320, .height = 200}, .cell_height = 20};
    const auto compact = HistoryModalGeometry::measure(metrics, true);

    check(compact.compact && compact.header.height == 0, "a compact history panel must reclaim its filter header");
    check(compact.footer.height > 0 && compact.search.height > 0, "compact windows must retain search and footer controls");
    const HistoryModalMetrics empty{.cell_height = 20};
    const auto hidden = HistoryModalGeometry::measure(empty, true);

    for (const auto area : {hidden.bounds, hidden.header, hidden.results, hidden.inspection, hidden.search, hidden.footer, hidden.inspectionContent(empty.chrome), hidden.inspectionActions(empty.chrome)}) {
      check(area.width >= 0 && area.height >= 0, "an empty viewport must never produce negative paint or input extents");
    }
  }

  void historyEntranceMovesPaintAndInputTogether() {
    const HistoryModalMetrics metrics{.viewport = {.width = 1200, .height = 800}, .cell_height = 20};
    auto shifted = HistoryModalGeometry::measure(metrics, true);
    const auto before = shifted;
    constexpr float entrance_offset = 12;

    shifted.offsetY(entrance_offset);
    check(shifted.viewport == before.viewport && shifted.bounds.y == before.bounds.y + entrance_offset, "history entrance must leave the dimmed viewport stationary");
    check(shifted.header.y == before.header.y + entrance_offset && shifted.results.y == before.results.y + entrance_offset && shifted.inspection.y == before.inspection.y + entrance_offset, "every content hit area must follow the panel entrance");
    check(shifted.search.y == before.search.y + entrance_offset && shifted.footer.y == before.footer.y + entrance_offset, "search and action hit areas must follow the panel entrance");
  }

  // A leading ! is the matcher's, which reads it as fzf does: the search sends it as typed, and
  // asks for failed commands only when the filter says so.
  void aLeadingBangIsSearchedAsTyped() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const auto request = browser.begin({.request_id = 1, .query = "!make"});

    check(request.query == "!make" && !request.failed_only, "the ! reaches the matcher");
    check(browser.begin({.request_id = 2, .query = "make", .failed_only = true}).failed_only, "the failed filter asks for failures");
  }

  void historyRowsProtectTheCommandBeforeFacts() {
    constexpr Rect wide{.width = 800, .height = 34};
    constexpr ChromeMetrics chrome;
    constexpr HistoryRowMeasurements advances{.command = 100, .cwd = 90, .time = 40, .agent = true, .has_cwd = true, .has_time = true};
    auto measured = advances;
    const auto complete = HistoryRowGeometry::derive(wide, chrome, wide.height, measured);
    constexpr Rect expected_frame{.x = 8, .y = 1, .width = 784, .height = 32};

    check(complete.frame == expected_frame, "row hit targets must retain their horizontal and vertical insets");
    check(!complete.provider.empty() && !complete.cwd.empty() && !complete.time.empty(), "a wide row must retain every fact");
    check(complete.command.right() + HistoryRowGeometry::fact_gap == complete.provider.x, "the command must leave the original gap before facts");
    measured.command = wide.width;
    const auto long_command = HistoryRowGeometry::derive(wide, chrome, wide.height, measured);

    check(long_command.cwd.empty() && !long_command.time.empty() && !long_command.provider.empty(), "a long command must remove its directory first");
    constexpr Rect narrow{.width = 260, .height = 34};
    const auto constrained = HistoryRowGeometry::derive(narrow, chrome, narrow.height, measured);

    check(constrained.time.empty() && !constrained.provider.empty(), "a narrow row must preserve the provider after dropping the date");
    constexpr Rect tiny{.width = 200, .height = 34};
    const auto command_only = HistoryRowGeometry::derive(tiny, chrome, tiny.height, measured);

    check(command_only.provider.empty() && command_only.cwd.empty() && command_only.time.empty(), "facts must yield to the minimum command width");
    measured.expanded = true;
    const auto card = HistoryRowGeometry::derive(wide, chrome, wide.height, measured);

    check(card.cwd.empty() && !card.time.empty(), "an expanded card must reserve its directory for the facts line");
  }

  // A row keeps what the runtime matched and told of the run, as the panel draws them.
  void rowsKeepWhatTheRuntimeMatched() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array ranges{HistoryRange{.start = 0, .end = 3}, HistoryRange{.start = 4, .end = 8}};
    const ds::Array excerpt_ranges{HistoryRange{.start = 6, .end = 11}};
    const ds::Array entries{
        HistoryEntry{.id = 1, .command = "git push", .host = "build", .run_count = 7, .ranges = ranges, .excerpt = "error: denied", .excerpt_ranges = excerpt_ranges},
        HistoryEntry{.id = 2, .command = "ls", .neighbour = true},
    };

    static_cast<void>(browser.begin({.request_id = 1, .query = "gitpush"}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = entries});
    const auto& matched = browser.reads().rows()[0];
    const auto& around = browser.reads().rows()[1];

    check(matched.ranges.view().size() == 2 && matched.ranges.view()[1].start == 4 && matched.ranges.view()[1].end == 8, "the row keeps the bytes the runtime matched");
    check(std::string_view{matched.excerpt} == "error: denied" && matched.excerpt_ranges.view().size() == 1 && matched.excerpt_ranges.view()[0].start == 6, "the row keeps the output's excerpt and its match");
    check(std::string_view{matched.host} == "build" && matched.run_count == 7, "the row keeps its machine and its runs");
    check(!matched.neighbour && around.neighbour && around.ranges.view().empty(), "a run shown around a match is told apart");
  }

  // Every page of a search asks for what its first did.
  void pagesKeepTheSearchCriteria() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "a"}, HistoryEntry{.id = 2, .command = "b"}};
    std::string host{"build"};
    std::string branch{"main"};
    std::string origin{"/src"};
    std::string shell{"fish"};

    static_cast<void>(browser.begin({.request_id = 1, .scope = HistoryScope::pane, .scope_value = std::uint64_t{9}, .sort = HistorySort::time, .since_ms = 5, .until_ms = 50, .exit_code = 2, .min_duration_ms = 10, .host = host, .branch = branch, .shell = shell, .preload = true, .output = true, .origin_pane = 9, .origin_cwd = origin}));
    // The caller's text is gone once the search began.
    host.assign("xxxxx");
    branch.assign("xxxx");
    origin.assign("xxxx");
    shell.assign("xxxx");
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = first});
    const auto page = browser.page(HistoryPage::older, 2);

    check(page && page->sort == HistorySort::time && page->since_ms == 5 && page->until_ms == 50 && page->exit_code == std::int32_t{2} && page->min_duration_ms == 10, "a page keeps the order and the filters");
    check(page && page->host == "build" && page->branch == "main" && page->shell == "fish" && page->origin_cwd == "/src" && page->origin_pane == 9, "a page keeps the text it asks with");
    check(page && page->preload && page->output && page->scope == HistoryScope::pane, "a page keeps the scope and what it searches");
    check(browser.reads().preloads() && browser.reads().searchesOutput(), "the panel reads what the search asks");
  }

  // A listing by time reads each next page past the last run the page before showed, so a delete
  // on an earlier page skips nothing; a refresh and going back read where each page began. A
  // ranked listing has no such run to read past, and pages by offset.
  void timePagesReadPastTheLastRunShown() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 9, .started_at_ms = 900, .command = "c"}, HistoryEntry{.id = 7, .started_at_ms = 700, .command = "b"}};
    const ds::Array second{HistoryEntry{.id = 4, .started_at_ms = 400, .command = "a"}, HistoryEntry{.id = 3, .started_at_ms = 300, .command = "z"}};

    static_cast<void>(browser.begin({.request_id = 1, .match = HistoryMatch::fuzzy, .distinct = true}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 10, .has_more = true, .entries = first});
    const auto older = browser.page(HistoryPage::older, 2);

    check(older && older->after_started_ms == 700 && older->after_id == 7 && older->snapshot_id == 10, "the next page reads past the last run shown");
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 10, .has_more = true, .entries = second});
    const auto refreshed = browser.refresh(3);

    check(refreshed.after_started_ms == 700 && refreshed.after_id == 7, "a refresh reads the page from where it began");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 11, .has_more = true, .entries = second});
    const auto third = browser.page(HistoryPage::older, 4);

    check(third && third->after_started_ms == 300 && third->after_id == 3, "and the page after it past its own last run");
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 11, .entries = std::span{first}.first(1)});
    const auto back = browser.page(HistoryPage::newer, 5);

    check(back && back->after_started_ms == 700 && back->after_id == 7, "going back reads the page before from where it began");
    browser.apply(HistoryResults{.request_id = 5, .snapshot_id = 11, .has_more = true, .entries = second});
    const auto top = browser.page(HistoryPage::newer, 6);

    check(top && top->after_id == 0 && top->offset == 0, "and the first page from the newest run");

    static_cast<void>(browser.begin({.request_id = 7, .query = "mk", .match = HistoryMatch::fuzzy, .distinct = true}));
    browser.apply(HistoryResults{.request_id = 7, .snapshot_id = 12, .has_more = true, .entries = first});
    const auto ranked = browser.page(HistoryPage::older, 8);

    check(ranked && ranked->after_id == 0 && ranked->offset == first.size(), "a ranked listing pages by offset");
  }

  // A raw listing's page holds matches and the runs around them: the next page starts after the
  // matches, and going back returns to the page it came from.
  void rawPagesCountOnlyTheMatches() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array first{HistoryEntry{.id = 1, .command = "x", .neighbour = true}, HistoryEntry{.id = 2, .command = "make"}, HistoryEntry{.id = 3, .command = "y", .neighbour = true}, HistoryEntry{.id = 4, .command = "make"}};
    const ds::Array second{HistoryEntry{.id = 5, .command = "make"}, HistoryEntry{.id = 6, .command = "z", .neighbour = true}};

    static_cast<void>(browser.begin({.request_id = 1, .query = "make", .neighbours = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = first});
    const auto older = browser.page(HistoryPage::older, 2);

    check(older && older->offset == 2 && older->neighbours == 1, "the next page starts after the two matches shown");
    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 1, .has_more = true, .entries = second});
    const auto third = browser.page(HistoryPage::older, 3);

    check(third && third->offset == 3, "and the one after it after its one match");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 1, .entries = second});
    const auto back = browser.page(HistoryPage::newer, 4);

    check(back && back->offset == 2, "going back returns to the page it came from");
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 1, .has_more = true, .entries = second});
    const auto start = browser.page(HistoryPage::newer, 5);

    check(start && start->offset == 0, "and then to the first");
  }

  // The inspector asks the runtime how every run of the command went, its days ending at the
  // person's next midnight, and reads the commands run around the one inspected in its pane.
  void inspectorReadsTheRunsAndTheContext() {
    constexpr std::int64_t day = 86'400'000;
    // 2026-11-27 15:00 in UTC+1: the day ends at 23:00 UTC.
    constexpr CalendarSample sampled{.now_ms = (20'784 * day) + (14 * day / 24), .utc_offset_min = 60};
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    const ds::Array page{HistoryEntry{.id = 10, .pane_id = 3, .command = "make test"}};
    const ds::Array<std::uint32_t, 20> days{0, 0, 0, 0, 0, 0, 9, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3};
    const ds::Array around{
        HistoryEntry{.id = 12, .command = "git push", .neighbour = true},
        HistoryEntry{.id = 11, .command = "git commit", .neighbour = true},
        HistoryEntry{.id = 10, .command = "make test"},
        HistoryEntry{.id = 9, .command = "vim", .neighbour = true},
        HistoryEntry{.id = 4, .command = "make test"},
    };

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = page});
    check(!browser.readRuns(2, sampled) && !browser.readContext(2), "nothing is read before the inspector opens");
    browser.setInspecting(true);
    const auto runs_read = browser.readRuns(3, sampled);
    const auto context_read = browser.readContext(4);

    check(runs_read && runs_read->entry_id == 10 && runs_read->days == HistoryRunStats::days && runs_read->until_ms == (20'785 * day) - (day / 24), "the runtime counts the entry's command, its days ending at the next local midnight");
    check(context_read && context_read->scope == HistoryScope::pane && std::get<std::uint64_t>(context_read->scope_value) == 3 && context_read->neighbours == HistoryLimits::context_entries, "the context reads the runs around it in its pane");
    check(!browser.readRuns(5, sampled) && !browser.readContext(5), "each is read once");
    check(!browser.apply(HistoryCommandStats{.request_id = 9, .found = true, .runs = 1}), "an answer to another request is not the command's");
    browser.apply(HistoryCommandStats{.request_id = 3, .found = true, .runs = 41, .measured = 30, .mean_duration_ms = 3000, .ended = 40, .succeeded = 30, .last_started_ms = 7, .last_exit = 1, .per_day = days.view()});
    const auto& stats = browser.reads().runStats();

    check(browser.reads().state().runs_phase == HistoryPhase::ready && stats.runs == 41 && stats.mean_duration_ms == 3000 && stats.ended == 40 && stats.succeeded == 30 && stats.last_exit == std::int32_t{1}, "the runtime's counts are kept");
    check(std::ranges::equal(stats.per_day, days.view().last(HistoryRunStats::days)), "the days kept end today");
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 2, .entries = around});
    check(browser.reads().state().context_phase == HistoryPhase::ready && browser.reads().contextCount() == 4, "the runs around it are kept, it aside");
    check(browser.reads().contextAt(0).command == "git push" && browser.reads().contextAt(0).newer && browser.reads().contextAt(2).command == "vim" && !browser.reads().contextAt(2).newer, "newer runs come before it, older after");
    browser.setInspecting(false);
    check(browser.reads().contextCount() == 0 && browser.reads().state().runs_phase == HistoryPhase::idle, "closing the inspector forgets them");
  }

  // The inspector tells how many runs, how long they take, how often they succeed, when the last
  // ran and how it ended, and a bar for each day's runs.
  void runFactsTellTheRuns() {
    constexpr std::int64_t hour = 3'600'000;
    constexpr CalendarSample sampled{.now_ms = 1000 * hour};
    HistoryRunStats stats{.runs = 41, .measured = 30, .mean_duration_ms = 3000, .ended = 40, .succeeded = 30, .last_started_ms = 998 * hour, .last_exit = 1};

    stats.per_day.atMut(HistoryRunStats::days - 3) = 8;
    stats.per_day.atMut(HistoryRunStats::days - 2) = 1;
    stats.per_day.atMut(HistoryRunStats::days - 1) = 4;
    const auto counted = HistoryRunFacts::derive(stats, sampled);
    const auto one = HistoryRunFacts::derive(HistoryRunStats{.runs = 1, .last_started_ms = 998 * hour, .last_exit = 0}, sampled);

    check(counted.runs.view() == "41 runs" && one.runs.view() == "1 run", "every run is counted");
    check(counted.mean.view() == "3.0s", "the mean is of the runs whose end was told");
    check(counted.success.view() == "75% of 40", "the success rate is of the runs that ended");
    check(counted.last.view() == "2h ago  exit 1" && counted.last_color == PaletteRole::red, "the last run's age and its failure");
    check(one.last.view() == "2h ago  ✓" && one.last_color == PaletteRole::green && one.mean.view().empty() && one.success.view().empty(), "a success, and nothing the runtime could not tell");
    check(counted.per_day.view() == "···········█▁▄  4 today", "each day a bar against the busiest, a day without runs a dot");
    check(HistoryRunFacts::derive({}, sampled).runs.view().empty(), "no run tells nothing");
  }

  // The panel asks to watch once; a connection that ended knows no watch.
  void watchIsForgottenWithTheConnection() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};

    check(browser.watch(true) && !browser.watch(true) && browser.reads().watching(), "a watch is asked for once");
    browser.suspend();
    check(!browser.reads().watching() && browser.watch(true), "a runtime connected again is asked again");
    check(browser.watch(false) && !browser.watch(false), "and told once to stop");
  }

  const telar::testing::Case case_owned_search_and_pages{"history.owned_search_and_pages", ownedSearchAndPages};
  const telar::testing::Case case_delete_keeps_the_position{"history.delete_keeps_the_position", deleteKeepsThePosition};
  const telar::testing::Case case_deletes_queue{"history.deletes_queue", deletesQueue};
  const telar::testing::Case case_details_retry_and_fail_alone{"history.details_retry_and_fail_alone", detailsRetryAndFailAlone};
  const telar::testing::Case case_rendered_choices_never_retarget_a_command{"history.rendered_choices_never_retarget_a_command", renderedChoicesNeverRetargetACommand};
  const telar::testing::Case case_bounded_requests_and_stale_failures{"history.bounded_requests_and_stale_failures", boundedRequestsAndStaleFailures};
  const telar::testing::Case case_allocation_failure_is_atomic{"history.allocation_failure_is_atomic", allocationFailureIsAtomic};
  const telar::testing::Case case_inspection_allocation_failure{"history.inspection_allocation_failure", inspectionAllocationFailure};
  const telar::testing::Case case_inspection_and_deletion{"history.inspection_and_deletion", inspectionAndDeletion};
  const telar::testing::Case case_bounded_commands_and_selected_reads{"history.bounded_commands_and_selected_reads", boundedCommandsAndSelectedReads};
  const telar::testing::Case case_selected_command_failures{"history.selected_command_failures", selectedCommandFailures};
  const telar::testing::Case case_command_preview_boundaries{"history.command_preview_boundaries", commandPreviewBoundaries};
  const telar::testing::Case case_selected_command_allocation_failure{"history.selected_command_allocation_failure", selectedCommandAllocationFailure};
  const telar::testing::Case case_plain_text_fixtures{"history.plain_text_fixtures", plainTextFixtures};
  const telar::testing::Case case_history_panel_preserves_the_search_position{"history.history_panel_preserves_the_search_position", historyPanelPreservesTheSearchPosition};
  const telar::testing::Case case_history_inspection_replaces_only_the_narrow_list{"history.history_inspection_replaces_only_the_narrow_list", historyInspectionReplacesOnlyTheNarrowList};
  const telar::testing::Case case_history_compact_windows_keep_nonnegative_bands{"history.history_compact_windows_keep_nonnegative_bands", historyCompactWindowsKeepNonnegativeBands};
  const telar::testing::Case case_history_entrance_moves_paint_and_input_together{"history.history_entrance_moves_paint_and_input_together", historyEntranceMovesPaintAndInputTogether};
  const telar::testing::Case case_a_leading_bang_is_searched_as_typed{"history.a_leading_bang_is_searched_as_typed", aLeadingBangIsSearchedAsTyped};
  const telar::testing::Case case_refresh_keeps_the_selected_command{"history.refresh_keeps_the_selected_command", refreshKeepsTheSelectedCommand};
  const telar::testing::Case case_refresh_keeps_the_inspected_output{"history.refresh_keeps_the_inspected_output", refreshKeepsTheInspectedOutput};
  const telar::testing::Case case_failed_search_leaves_no_rows_of_the_query_before{"history.failed_search_leaves_no_rows_of_the_query_before", failedSearchLeavesNoRowsOfTheQueryBefore};
  const telar::testing::Case case_search_from_a_later_page_selects_the_best_match{"history.search_from_a_later_page_selects_the_best_match", searchFromALaterPageSelectsTheBestMatch};
  const telar::testing::Case case_deletes_wait_for_their_undo{"history.deletes_wait_for_their_undo", deletesWaitForTheirUndo};
  const telar::testing::Case case_marks_keep_their_order_across_searches{"history.marks_keep_their_order_across_searches", marksKeepTheirOrderAcrossSearches};
  const telar::testing::Case case_history_rows_protect_the_command_before_facts{"history.history_rows_protect_the_command_before_facts", historyRowsProtectTheCommandBeforeFacts};
  const telar::testing::Case case_rows_keep_what_the_runtime_matched{"history.rows_keep_what_the_runtime_matched", rowsKeepWhatTheRuntimeMatched};
  const telar::testing::Case case_pages_keep_the_search_criteria{"history.pages_keep_the_search_criteria", pagesKeepTheSearchCriteria};
  const telar::testing::Case case_time_pages_read_past_the_last_run_shown{"history.time_pages_read_past_the_last_run_shown", timePagesReadPastTheLastRunShown};
  const telar::testing::Case case_raw_pages_count_only_the_matches{"history.raw_pages_count_only_the_matches", rawPagesCountOnlyTheMatches};
  const telar::testing::Case case_inspector_reads_the_runs_and_the_context{"history.inspector_reads_the_runs_and_the_context", inspectorReadsTheRunsAndTheContext};
  const telar::testing::Case case_run_facts_tell_the_runs{"history.run_facts_tell_the_runs", runFactsTellTheRuns};
  const telar::testing::Case case_watch_is_forgotten_with_the_connection{"history.watch_is_forgotten_with_the_connection", watchIsForgottenWithTheConnection};

}
