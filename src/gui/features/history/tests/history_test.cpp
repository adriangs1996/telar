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

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::history;

  // The feature's use cases under the names the browser's methods had, so each assertion reads as
  // it did; every call goes through the feature's boundary, its reads through HistoryView.
  struct BrowserState {
    explicit BrowserState(telar::Memory& memory)
        : history(memory) {}

    State history;
  };

  class Browser : private BrowserState, public HistoryView {
  public:
    static constexpr auto page_entries = HistoryLimits::page_entries;
    static constexpr auto maximum_requests = HistoryLimits::maximum_requests;
    static constexpr auto maximum_command_bytes = HistoryLimits::maximum_command_bytes;
    static constexpr auto maximum_output_bytes = HistoryLimits::maximum_output_bytes;

    explicit Browser(telar::Memory& memory)
        : BrowserState(memory),
          HistoryView(view(history)) {}

    Browser(const Browser&) = delete;
    Browser& operator=(const Browser&) = delete;

    QueryHistory begin(QueryHistory query) {
      return search(history, query);
    }

    std::optional<QueryHistory> page(HistoryPage direction, std::uint64_t request_id) {
      return features::history::page(history, direction, request_id);
    }

    QueryHistory refresh(std::uint64_t request_id) {
      return features::history::refresh(history, request_id);
    }

    template <typename Message>
    bool apply(const Message& message) {
      return receive(history, message);
    }

    bool select(std::size_t index) {
      return features::history::select(history, index);
    }

    void setInspecting(bool enabled) {
      inspect(history, enabled);
    }

    std::optional<QueryHistory> readCommand(std::uint64_t request_id) {
      return features::history::readCommand(history, request_id);
    }

    std::optional<ReadHistoryOutput> readOutput(std::uint64_t request_id) {
      return features::history::readOutput(history, request_id);
    }

    DeleteHistory erase(std::uint64_t id, std::uint64_t request_id) {
      return features::history::erase(history, id, request_id);
    }

    bool fail(std::uint64_t request_id, std::string_view message) {
      return features::history::fail(history, request_id, message);
    }

    void suspend() noexcept {
      features::history::suspend(history);
    }
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

    const std::array first{HistoryEntry{.id = 1, .pane_id = 1, .command = "first"}, HistoryEntry{.id = 2, .pane_id = 1, .command = "second"}};

    check(browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 4, .has_more = true, .entries = first}), "the active page must commit");
    const auto older = browser.page(HistoryPage::older, 2);

    check(older && older->offset == first.size() && older->snapshot_id == 4 && older->query == "compiler errors", "older pages must retain the insertion boundary and search filters");
    check(browser.rows().size() == first.size() && browser.state().phase == HistoryPhase::loading, "pending pages must retain their visible rows");
    check(!browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 4, .entries = first}), "late page replies must not unlock a newer request");

    const std::array second{HistoryEntry{.id = 3, .pane_id = 1, .command = "older"}};

    check(browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 4, .entries = second}), "the older page must replace the previous rows");
    check(!browser.canPage(HistoryPage::older) && browser.canPage(HistoryPage::newer), "page controls must reflect the actual page boundary");
    const auto newer = browser.page(HistoryPage::newer, 3);

    check(newer && newer->offset == 0 && newer->snapshot_id == 4, "newer paging must saturate at the first page");
    browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 4, .has_more = true, .entries = first});
    check(browser.state().selection == first.size() - 1, "returning to a newer page must select its last row");
    const auto refreshed = browser.refresh(4);

    check(refreshed.offset == 0 && refreshed.snapshot_id == 0, "a refresh must choose a new insertion boundary");
  }

  void renderedChoicesNeverRetargetACommand() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};

    check(!browser.choice(), "an idle browser must not offer a command choice");
    const std::array entries{HistoryEntry{.id = 1, .command = "first"}, HistoryEntry{.id = 2, .command = "second"}};

    static_cast<void>(browser.begin({.request_id = 1}));
    browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .has_more = true, .entries = entries});
    const auto presented = browser.choice();
    if (!presented) {
      throw std::runtime_error{"a ready page must provide a selected choice"};
    }

    check(browser.accepts(*presented), "a ready page must accept its selected choice");
    check(!browser.acceptsRow({.index = entries.size(), .revision = browser.revision()}), "a choice outside the page must be rejected");
    const auto previous_view = browser.viewVersion();

    browser.select(1);
    check(!browser.accepts(*presented), "selection must not retarget a previously drawn submit action");
    check(browser.acceptsRow(*presented), "selection must preserve row choices from the same page");
    check(browser.revision() == presented->revision && browser.viewVersion() > previous_view, "selection must publish view changes without invalidating the content revision");
    browser.select(0);
    check(browser.accepts(*presented), "returning to the selected row on the same page must retain the original submission guard");
    browser.setInspecting(true);
    check(browser.acceptsRow(*presented), "opening inspection must preserve ready row choices until a detail request changes the content");
    const auto selected = browser.choice();
    if (!selected) {
      throw std::runtime_error{"the new selection must provide its own choice"};
    }

    check(browser.accepts(*selected), "the new selection must accept its own choice");
    static_cast<void>(browser.page(HistoryPage::older, 2));
    check(!browser.choice() && !browser.acceptsRow(*selected), "loading must disable the old choice while retaining its visible rows");
    check(browser.rows().size() == entries.size(), "the pending page must preserve displayed rows");
    const std::array replacement{HistoryEntry{.id = 3, .command = "replacement"}};

    browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 1, .entries = replacement});
    check(!browser.acceptsRow(*selected), "a completed page must not reuse a previous row index as a command choice");
    const auto replaced = browser.choice();
    if (!replaced) {
      throw std::runtime_error{"the replacement must provide its own choice"};
    }

    check(browser.rows()[replaced->index].id == replacement.front().id, "the replacement must select its own command");
    static_cast<void>(browser.refresh(3));
    browser.fail(3, "search failed");
    check(!browser.choice() && !browser.accepts(*replaced), "a failed search must not restore the previous choice");
    static_cast<void>(browser.begin({.request_id = 4}));
    browser.apply(HistoryResults{.request_id = 4, .snapshot_id = 2});
    check(!browser.choice(), "an empty ready page must not offer a command choice");
    browser.suspend();
    check(!browser.accepts(*replaced), "disconnect must invalidate a drawn choice");
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

    check(rejected && browser.state().phase == HistoryPhase::failed, "request saturation must block submission without growing storage");
    check(browser.owns(1) && !browser.fail(1, "stale failure"), "an obsolete failure must retire its request without replacing the current error");
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    check(browser.state().phase == HistoryPhase::loading, "retiring a stale request must restore bounded request capacity");
    browser.suspend();
    check(!browser.owns(sequence) && browser.state().phase == HistoryPhase::idle, "disconnect must invalidate every history request");
  }

  void allocationFailureIsAtomic() {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{4} * 1024;
    BudgetAllocator budget{system, allocation_budget};
    telar::MemoryAdapter adapter{budget};

    {
      Browser browser{adapter};

      static_cast<void>(browser.begin({.request_id = 1}));
      const std::array initial{HistoryEntry{.id = 1, .pane_id = 1, .command = "retained"}};

      browser.apply(HistoryResults{.request_id = 1, .snapshot_id = 1, .entries = initial});
      static_cast<void>(browser.begin({.request_id = 2}));
      const auto live_bytes = budget.liveBytes();
      const std::string large_command(decltype(browser)::maximum_output_bytes, 'x');
      const std::array replacement{HistoryEntry{.id = 2, .pane_id = 1, .command = large_command}};
      bool rejected = false;

      try {
        browser.apply(HistoryResults{.request_id = 2, .snapshot_id = 2, .entries = replacement});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      check(rejected && browser.state().phase == HistoryPhase::failed, "allocation failure must close input authority");
      check(browser.rows().size() == 1 && browser.rows().front().command == "retained", "allocation failure must preserve the previous complete page");
      check(budget.liveBytes() == live_bytes, "failed page staging must release every temporary allocation");
      static_cast<void>(browser.begin({.request_id = 3}));
      browser.apply(HistoryResults{.request_id = 3, .snapshot_id = 3, .entries = initial});
      check(browser.command(1) == "retained", "a later successful query must restore submission authority");
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
      const std::array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "available"}};

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

      check(rejected && browser.state().output_phase == HistoryPhase::failed && !browser.error().empty(), "inspection allocation failure must replace its loading indicator with a bounded error");
      check(browser.state().phase == HistoryPhase::ready && browser.command(1) == "available", "inspection failure must preserve the current command page and input authority");
      browser.setInspecting(false);
      browser.setInspecting(true);
      static_cast<void>(browser.readOutput(3));
      browser.apply(HistoryOutput{.request_id = 3, .id = 1, .content = byteView("recovered")});
      check(browser.output() == "recovered" && browser.error().empty(), "a later successful inspection must clear its previous error");
    }

    check(budget.liveBytes() == 0, "failed inspections must release every injected allocation");
  }

  void inspectionAndDeletion() {
    SystemAllocator memory;
    telar::MemoryAdapter adapted{memory};
    Browser browser{adapted};
    std::uint64_t sequence = 0;
    const auto query = browser.begin({.request_id = ++sequence});
    const std::array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = "first"}, HistoryEntry{.id = 2, .pane_id = 1, .command = "second"}};

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
    const auto rows_version = browser.rowsVersion();
    std::string output = "\x1b[31mred\x1b[0m\r\n\x1b]2;hidden\aend";

    browser.apply(HistoryOutput{.request_id = second->request_id, .id = 2, .truncated = true, .observed_bytes = output.size(), .content = byteView(output)});
    output.assign("reused network storage");
    check(browser.output() == "red\nend" && browser.state().output_truncated, "inspection must own sanitized output and preserve truncation status");
    check(browser.rowsVersion() == rows_version, "inspection changes must not invalidate projected command rows");

    const auto deletion = browser.erase(2, ++sequence);

    check(browser.rows().size() == 2 && browser.deleting(), "deletion must leave rows present until runtime confirmation");
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
      std::array<HistoryEntry, decltype(browser)::page_entries> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        entries[index] = {.id = index + 1, .pane_id = 1, .command = large_command};
      }

      static_cast<void>(browser.begin({.request_id = ++sequence}));
      browser.apply(HistoryResults{.request_id = sequence, .snapshot_id = 1, .entries = entries});
      check(budget.failures() == 0 && budget.liveBytes() < allocation_budget, "a page of maximal commands must fit its bounded cache and previews");
      check(browser.rows().front().command.size() == Storage::command_preview_bytes && browser.command(1) == large_command, "bounded previews must retain complete cached commands for input");
      check(browser.rows()[first_uncached - 1].command_complete && !browser.rows()[first_uncached].command_complete, "the shared command budget must admit only complete commands");
      browser.select(first_uncached);
      check(!browser.canSubmit(), "uncached previews must never authorize input");
      check(browser.selectedCommand() == browser.rows()[first_uncached].command, "an uncached selection must display only its owned preview");
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
      const auto rows_version = browser.rowsVersion();

      browser.apply(HistoryResults{.request_id = current->request_id, .entries = std::span{entries}.subspan(first_uncached + 1, 1)});
      check(browser.canSubmit() && browser.command(current->entry_id) == large_command, "only a complete matching reply may authorize the selected command");
      check(browser.selectedCommand() == large_command, "inspection must expose the complete selected command after its matching read");
      check(browser.rowsVersion() == rows_version && budget.failures() == 0, "selected detail must not rebuild the page or exceed its memory budget");
      static_cast<void>(browser.begin({.request_id = ++sequence}));
      check(!browser.canSubmit() && browser.state().command_phase == HistoryPhase::idle, "a new search must invalidate selected command ownership");
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
    std::array<HistoryEntry, cached_entries + 2> entries{};

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries[index] = {.id = index + 1, .pane_id = 1, .command = large_command};
    }

    entries.back().command_truncated = true;
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    browser.apply(HistoryResults{.request_id = sequence, .entries = entries});
    browser.select(entries.size() - 1);
    check(!browser.canSubmit() && !browser.readCommand(++sequence), "capture truncation must not be confused with a missing cached command");

    browser.select(cached_entries);
    static_cast<void>(browser.readCommand(++sequence));
    browser.apply(HistoryResults{.request_id = sequence, .entries = std::span{entries}.first(1)});
    check(!browser.canSubmit() && browser.state().command_phase == HistoryPhase::failed && browser.state().phase == HistoryPhase::ready, "mismatched entry identity must fail locally without replacing the page");
    check(!browser.readCommand(++sequence), "a failed full read must not cause an automatic retry loop");
    browser.select(0);
    browser.select(cached_entries);
    static_cast<void>(browser.readCommand(++sequence));
    check(browser.fail(sequence, "Entry disappeared") && !browser.canSubmit() && browser.state().phase == HistoryPhase::ready, "full-read request failure must remain local to its selection");
    browser.select(0);
    browser.select(cached_entries);
    const auto obsolete_request = ++sequence;

    static_cast<void>(browser.readCommand(obsolete_request));
    static_cast<void>(browser.begin({.request_id = ++sequence}));
    check(!browser.apply(HistoryResults{.request_id = obsolete_request, .entries = std::span{entries}.subspan(cached_entries, 1)}), "an obsolete full reply must not end a newer search");
    check(browser.state().phase == HistoryPhase::loading && browser.state().command_phase == HistoryPhase::idle, "query and selected-command phases must remain independent");
  }

  void commandPreviewBoundaries() {
    SystemAllocator memory;
    using Storage = HistoryLimits;
    std::string command(Storage::command_preview_bytes - 1, 'x');

    command += "🌱tail";
    const std::array entries{HistoryEntry{.id = 1, .pane_id = 1, .command = command}};
    telar::MemoryAdapter adapted{memory};
    Browser page{adapted};

    static_cast<void>(page.begin({.request_id = 1}));
    page.apply(HistoryResults{.request_id = 1, .entries = entries});
    check(page.rows().front().command.size() == Storage::command_preview_bytes - 1, "previews must stop before a split UTF-8 scalar");
    check(page.command(1) == command, "preview truncation must preserve complete canonical command bytes");
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
      std::array<HistoryEntry, cached_entries + 1> entries{};

      for (std::size_t index = 0; index < entries.size(); ++index) {
        entries[index] = {.id = index + 1, .pane_id = 1, .command = command};
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

      check(rejected && browser.state().command_phase == HistoryPhase::failed && !browser.canSubmit(), "a detail allocation failure must end loading without authorizing a preview");
      check(browser.state().phase == HistoryPhase::ready && budget.liveBytes() == live_bytes && !browser.owns(2), "detail allocation failure must retain page ownership and retire its request");
      browser.select(0);
      check(browser.canSubmit() && browser.command(1) == command, "a cached command must remain available after detail allocation failure");
    }

    check(budget.liveBytes() == 0 && budget.failures() != 0, "detail failure must release all injected memory");
  }

  void plainTextFixtures() {
    struct Example {
      std::string_view input;
      std::string_view expected;
    };

    constexpr auto examples = std::to_array<Example>({
        {.input = "\x1b[31mfail\x1b[0m\r\n", .expected = "fail\n"},
        {.input = "before\x1b]52;c;hidden\aafter", .expected = "beforeafter"},
        {.input = "a\x1bPpayload\x1b\\b\x1bXhidden\x1b\\c\x1b^private\ad\x1b_graphics\x1b\\e", .expected = "abcde"},
        {.input = "a\x1b(Bb\x1b[12;", .expected = "ab"},
        {.input = "café\t🌱\n", .expected = "café\t🌱\n"},
    });

    constexpr std::size_t output_capacity = 128;
    std::array<char, output_capacity> output{};

    for (const auto& example : examples) {
      const auto written = PlainText::strip(byteView(example.input), output);

      check(std::string_view{output.data(), written} == example.expected, "terminal control stripping must match the original scanner fixtures");
    }

    constexpr std::size_t bounded_capacity = 3;
    const auto written = PlainText::strip(byteView("abcdef"), std::span{output}.first(bounded_capacity));

    check(std::string_view{output.data(), written} == "abc" && PlainText::strip(byteView("text"), {}) == 0, "plain text output must respect empty and bounded destinations");
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

  void historySearchBorrowsOnlyTheEffectiveQuery() {
    constexpr std::string_view source = "!   compiler";
    const auto parsed = HistorySearch::parse(source, false);

    check(parsed.failed_only && parsed.query == "compiler", "the failure prefix must expose the command query");
    check(parsed.query.data() == source.data() + source.find("compiler"), "parsing a query must borrow its original storage");
    check(HistorySearch::parse("!   ", false).query.empty(), "a failure-only search must still group results by day");
    check(HistorySearch::parse(" !compiler", false).query == " !compiler", "only a leading failure marker changes the filter");
    check(HistorySearch::parse("!\tcompiler", false).query == "\tcompiler", "the failure prefix must preserve non-space query bytes");
    check(HistorySearch::parse("compiler", true).failed_only, "an explicit failure filter must survive an ordinary query");
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

  const telar::testing::Case case_owned_search_and_pages{"history.owned_search_and_pages", ownedSearchAndPages};
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
  const telar::testing::Case case_history_search_borrows_only_the_effective_query{"history.history_search_borrows_only_the_effective_query", historySearchBorrowsOnlyTheEffectiveQuery};
  const telar::testing::Case case_history_rows_protect_the_command_before_facts{"history.history_rows_protect_the_command_before_facts", historyRowsProtectTheCommandBeforeFacts};

}
