#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "telar_base/memory/allocator.hpp"
#include "telar_wire/codecs/telar_cells.hpp"
#include <array>
#include <cstdint>
#include <string>
#include <vector>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.terminal;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  void foldsCountShownRows() {
    constexpr std::uint64_t any_row = 42;
    constexpr std::uint32_t first_fold = 10;
    constexpr std::uint32_t overlapping = 12;
    constexpr std::uint32_t later_fold = 30;
    constexpr std::uint32_t fold_rows = 4;
    constexpr std::uint32_t later_rows = 5;
    constexpr std::uint32_t joined_rows = overlapping + fold_rows - first_fold;
    constexpr std::uint64_t after_first = first_fold + joined_rows;
    constexpr std::uint64_t after_later = later_fold + later_rows + 1;
    constexpr std::uint64_t indexes = 40;
    constexpr std::uint64_t total = 50;
    telar::testing::TestMemory memory;
    application::FoldMap<> folds{memory};

    check(folds.display(any_row) == any_row && folds.row(any_row) == any_row, "without folds rows are their own display index");
    const ds::Array<application::FoldMap<>::Span, 3> spans{{{.first = later_fold, .count = later_rows}, {.first = first_fold, .count = fold_rows}, {.first = overlapping, .count = fold_rows}}};

    folds.assign(spans);
    check(folds.spans().size() == 2 && folds.spans()[0].first == first_fold && folds.spans()[0].count == joined_rows, "overlapping folds join, in order");
    check(folds.hides(first_fold) && folds.hides(after_first - 1) && !folds.hides(after_first) && !folds.hides(first_fold - 1), "a fold hides its rows only");
    check(folds.display(first_fold - 1) == first_fold - 1 && folds.display(after_first) == first_fold && folds.display(after_later) == after_later - joined_rows - later_rows, "shown rows count without the hidden ones above");
    check(folds.display(overlapping) == first_fold, "a hidden row takes the index of the first shown row under its fold");
    for (std::uint64_t index = 0; index < indexes; ++index) {
      const auto row = folds.row(index);

      check(!folds.hides(row) && folds.display(row) == index, "a display index names one shown row and back");
    }

    check(folds.shownRows(total) == total - joined_rows - later_rows, "the shown rows of a scrollback leave the hidden out");
  }

  // A reply carrying `rows` rows of one cell, "a", "b", ... from stable row `from`.
  struct RowsReply {
    static constexpr std::size_t encoded_capacity = 1024;
    static constexpr std::size_t letter_count = 26;

    std::vector<Cell> cells;
    ds::Array<Byte, encoded_capacity> encoded{};
    std::vector<Byte> flags;
    ds::Array<Byte, letter_count> letters{};
    PaneRows reply{};

    RowsReply(PaneRows header, std::uint16_t rows) {
      for (std::size_t index = 0; index < letters.size(); ++index) {
        letters.atMut(index) = static_cast<Byte>('a' + index);
      }

      for (std::uint16_t row = 0; row < rows; ++row) {
        cells.push_back(Cell{.text = std::span<const Byte>{letters}.subspan(row % letters.size(), 1)});
        flags.push_back(0);
      }

      reply = header;
      reply.pane_id = 1;
      reply.cols = 1;
      reply.rows = rows;
      reply.text_metadata = TextMetadata{.row_flags = flags};
      reply.cells = CellRunCodec::encode(cells, encoded.viewMut());
    }
  };

  // A document shows its rows in display rows of its own, more or fewer than it stands for,
  // beside folds that hide theirs.
  void documentsShowTheirOwnRows() {
    SystemAllocator system;
    telar::BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter memory{budget};
    ds::Option<application::FoldMap<>> held{std::in_place, memory};
    auto& folds = held.getMut();
    // A fold of rows 10-14, a document that shows rows 20-22 in six display rows, and one that
    // shows rows 40-49 in four.
    constexpr std::uint32_t fold = 10;
    constexpr std::uint32_t fold_rows = 5;
    constexpr std::uint32_t longer = 20;
    constexpr std::uint32_t longer_rows = 3;
    constexpr std::uint32_t longer_shown = 6;
    constexpr std::uint32_t shorter = 40;
    constexpr std::uint32_t shorter_rows = 10;
    constexpr std::uint32_t shorter_shown = 4;
    // Where each document starts on screen, after the rows the ones above it hide or add.
    constexpr std::uint32_t longer_display = longer - fold_rows;
    constexpr std::uint32_t shorter_display = shorter - fold_rows + (longer_shown - longer_rows);
    constexpr std::uint64_t between_documents = 30;
    constexpr std::uint64_t total_rows = 100;
    const ds::Array<application::FoldMap<>::Span, 3> spans{{
        {.first = shorter, .count = shorter_rows, .shown = shorter_shown},
        {.first = fold, .count = fold_rows},
        {.first = longer, .count = longer_rows, .shown = longer_shown},
    }};

    folds.assign(spans);
    check(folds.display(fold - 1) == fold - 1 && folds.display(fold + 2) == fold && folds.display(fold + fold_rows) == fold, "a fold still hides its rows");
    check(folds.display(longer) == longer_display && folds.display(longer + 2) == longer_display + 2 && folds.display(longer + longer_rows) == longer_display + longer_shown, "a document longer than its rows pushes the rows below down");
    check(folds.row(longer_display) == longer && folds.row(longer_display + 2) == longer + 2 && folds.row(longer_display + longer_shown - 1) == longer + 2 && folds.row(longer_display + longer_shown) == longer + longer_rows, "its display rows past its rows stand for its last row");
    check(folds.display(shorter) == shorter_display && folds.display(shorter + 3) == shorter_display + 3 && folds.display(shorter + shorter_rows - 1) == shorter_display + 3 && folds.display(shorter + shorter_rows) == shorter_display + shorter_shown && folds.row(shorter_display + shorter_shown) == shorter + shorter_rows, "a document shorter than its rows pulls the rows below up");
    check(folds.shownRows(total_rows) == total_rows - fold_rows + longer_shown - longer_rows - (shorter_rows - shorter_shown) && folds.shownRows(longer + 2) == longer + 2 - fold_rows, "shown rows count each document's own");
    check(folds.showing(longer_display + 1) == &folds.spans()[1] && folds.showing(between_documents) == nullptr && folds.showing(fold) == nullptr, "a display row knows the document it shows");
    check(!folds.hides(longer + longer_rows) && folds.hides(fold + 2) && folds.hides(shorter + shorter_shown + 2) && !folds.hides(shorter + 1), "rows past what a document shows are hidden");

    constexpr std::uint32_t cover = 18;
    constexpr std::uint32_t cover_rows = 10;
    const ds::Array<application::FoldMap<>::Span, 2> covered{{{.first = longer, .count = longer_rows, .shown = longer_shown}, {.first = cover, .count = cover_rows}}};

    folds.assign(covered);
    check(folds.spans().size() == 1 && folds.spans()[0].shown == 0 && folds.spans()[0].count == cover_rows, "a fold over a document hides it");

    held.reset();
    check(budget.liveBytes() == 0, "the folds give their memory back");
  }

  void rowCacheKeepsRowsByStableNumber() {
    constexpr std::uint64_t generation = 3;
    constexpr std::uint64_t request = 7;
    constexpr std::uint64_t from = 100;
    constexpr std::uint16_t count = 4;
    constexpr std::uint64_t third = from + 2;
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    RowCache<telar::ConcurrentMemory> cache{memory};

    cache.number(generation);
    check(cache.empty() && !cache.find(0), "a cache holds nothing before its first rows");
    cache.ask(request, from, count);
    check(!cache.missing(from, from + count - 1) && cache.missing(from, from + count) == from + count, "rows asked for are not missing");
    const RowsReply reply{{.request_id = request, .generation = generation, .from = from}, count};

    check(cache.store(reply.reply, 1) && !cache.full(), "a reply of the cache's generation is kept and settles its request");
    const auto row = cache.find(third);

    check(row && row->cells.size() == 1 && row->cells.front().utf8() == "c", "a row is found by its stable number");
    check(!cache.find(third + RowCache<telar::ConcurrentMemory>::slot_count), "a slot answers only for the row it holds");
    const RowsReply stale{{.request_id = request + 1, .generation = generation - 1, .from = from}, 1};

    check(!cache.store(stale.reply, 1), "rows of another generation are not kept");
    cache.number(generation + 1);
    check(!cache.find(third), "a new generation forgets the rows numbered by the old one");
    cache.release();
    check(cache.empty(), "a released cache gives its slots back");
  }

  // Kept rows keep their hyperlinks; a screen put together from drawn rows answers for them.
  void keptRowsKeepTheirLinks() {
    constexpr std::uint64_t generation = 2;
    constexpr std::uint64_t from = 30;
    constexpr std::uint16_t columns = 4;
    constexpr std::uint16_t rows = 2;
    constexpr std::uint16_t linked_column = 1;
    constexpr std::uint32_t linked_cells = 2;
    constexpr std::string_view uri = "https://example.com/";
    constexpr ds::Array<Byte, 1> letter{'x'};
    const std::vector<Cell> cells(static_cast<std::size_t>(columns) * rows, Cell{.text = letter});
    ds::Array<Byte, RowsReply::encoded_capacity> encoded{};
    const ds::Array<Byte, rows> flags{0, static_cast<Byte>(RowFlag::hyperlinks)};
    const ds::Array links{MetadataLink{.offset = 0, .len = static_cast<std::uint16_t>(uri.size())}};
    const ds::Array runs{MetadataRun{.start = columns + linked_column, .len = linked_cells, .link_index = 0}};
    const auto uri_bytes = byteView(uri);
    const PaneRows reply{.request_id = 1, .pane_id = 1, .generation = generation, .from = from, .cols = columns, .rows = rows, .text_metadata = TextMetadata{.row_flags = flags, .links = links, .runs = runs, .uris = uri_bytes}, .cells = CellRunCodec::encode(cells, encoded.viewMut())};
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    RowCache<telar::ConcurrentMemory> cache{memory};

    cache.number(generation);
    check(cache.store(reply, columns), "rows with links are kept");
    std::string kept;
    std::uint16_t kept_column = 0;

    cache.links(from + 1, [&](const RowCache<telar::ConcurrentMemory>::LinkView& link) {
      kept.assign(link.uri);
      kept_column = link.column;
      check(link.length == linked_cells, "a kept link covers its cells");
    });

    check(kept == uri && kept_column == linked_column, "a kept row keeps its link and target");
    bool none = true;

    cache.links(from, [&](const RowCache<telar::ConcurrentMemory>::LinkView&) {
      none = false;
    });

    check(none, "a row without links has none");

    // The second kept row drawn first, as a folded view may draw it.
    Screen<telar::ConcurrentMemory> drawn{memory};
    const auto row = cache.find(from + 1);
    const ds::Array spans{row->cells, std::span<const CellValue>{}};
    const ds::Array<Byte, rows> drawn_flags{row->flags, 0};
    const ds::Array drawn_runs{MetadataRun{.start = linked_column, .len = linked_cells, .link_index = 0}};

    drawn.compose(columns, spans, drawn_flags, TextMetadata{.row_flags = drawn_flags, .links = links, .runs = drawn_runs, .uris = uri_bytes});
    check(drawn.rows() == rows && drawn.scroll().offset == 0 && drawn.linkAt(linked_column) == uri, "a composed screen holds its rows' links");
    const auto found = application::terminal::links::CellLinks::resolve(drawn, CellPosition{.x = linked_column, .y = 0});

    check(found && found->start.x == linked_column && found->start.y == 0, "a link on a composed screen resolves where it is drawn");
  }

  void sessionAsksForRowsBeyondTheScreen() {
    constexpr std::uint32_t total = 1000;
    constexpr std::uint64_t generation = 5;
    constexpr std::uint64_t trimmed = 40;
    constexpr std::uint64_t dropped = 12;
    constexpr std::uint64_t first = 500;
    constexpr std::uint64_t last = 700;
    constexpr std::uint64_t second_from = first + RowCache<telar::ConcurrentMemory>::request_rows;
    constexpr std::uint16_t kept = 3;
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = total, .offset = total - 1}};

    deliverSingleCell(client, frame);
    client.requestRows(1, 0, first);
    check(transport.count(ClientTag::read_pane_rows) == 0, "rows are not asked for before the runtime numbers them");
    deliver(client, PaneScrollback{.pane_id = 1, .generation = generation, .trimmed = trimmed});
    client.requestRows(1, first, last);
    const auto asked = transport.last<ReadPaneRows>();

    check(transport.count(ClientTag::read_pane_rows) == 2 && asked.from == second_from && asked.count == last - second_from + 1, "rows are asked for in bounded requests");
    client.requestRows(1, first, last);
    check(transport.count(ClientTag::read_pane_rows) == 2, "rows already asked for are not asked for again");
    const RowsReply reply{{.request_id = asked.request_id, .generation = generation, .from = asked.from}, kept};

    deliver(client, reply.reply);
    check(client.findPane(1)->rows.find(asked.from + 1).hasValue(), "the reply's rows are kept");
    deliver(client, PaneScrollback{.pane_id = 1, .generation = generation, .trimmed = trimmed + dropped});
    check(client.takeDroppedRows(1) == dropped && client.takeDroppedRows(1) == 0, "the view learns how many rows the scrollback dropped, once");

    Transport legacy_transport;
    TestSession legacy{memory, legacy_transport};

    legacy.connected(1, false);
    check(!legacy.readsRows(), "a runtime without scrollback rows is not asked for them");
  }

  void foldedBlocksHideTheirOutput() {
    constexpr std::uint32_t total = 100;
    constexpr std::uint32_t first_row = 10;
    constexpr std::uint16_t first_rows = 2;
    constexpr std::uint32_t second_row = 40;
    constexpr std::uint32_t third_row = 60;
    constexpr std::uint64_t trimmed = 7;
    constexpr std::uint32_t dropped = 2;
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = total, .offset = total - 1}};

    deliverSingleCell(client, frame);
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = trimmed});
    const auto blocks_at = [](std::uint32_t shift) {
      return ds::Array{CommandBlock{.row = first_row - shift, .rows = first_rows, .state = CommandBlockState::succeeded, .command = "ls"}, CommandBlock{.row = second_row - shift, .rows = 1, .state = CommandBlockState::failed, .status = 1, .command = "make"}, CommandBlock{.row = third_row - shift, .rows = 1, .state = CommandBlockState::running, .command = "tail"}};
    };

    const auto blocks = blocks_at(0);

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    client.fold(1, 0, true);
    const auto& pane = *client.findPane(1);
    const auto output = first_row + first_rows;

    check(client.folded(1, 0) && pane.folds.hides(output) && pane.folds.hides(second_row - 1) && !pane.folds.hides(second_row) && !pane.folds.hides(output - 1), "a fold hides the rows between its prompt and the next");
    client.foldAll(1, true);
    check(client.folded(1, 1) && !client.folded(1, 2), "folding all leaves the running command open");
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = trimmed + dropped});
    const auto moved = blocks_at(dropped);

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = moved});
    check(client.folded(1, 0) && client.folded(1, 1) && pane.folds.hides(output - dropped) && !pane.folds.hides(second_row - dropped), "folds stay with their blocks when the scrollback drops rows above them");
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 2, .trimmed = 0});
    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    check(client.folded(1, 0) && client.folded(1, 1) && !client.folded(1, 2), "renumbered rows keep the folds by block order");
    client.foldAll(1, false);
    check(!client.folded(1, 0) && pane.folds.empty(), "unfolding all shows every row");
  }

  const telar::testing::Case case_documents_show_their_own_rows{"scroll.documents_show_their_own_rows", documentsShowTheirOwnRows};
  const telar::testing::Case case_folds_count_shown_rows{"scroll.folds_count_shown_rows", foldsCountShownRows};
  const telar::testing::Case case_row_cache_keeps_rows_by_stable_number{"scroll.row_cache_keeps_rows_by_stable_number", rowCacheKeepsRowsByStableNumber};
  const telar::testing::Case case_kept_rows_keep_their_links{"scroll.kept_rows_keep_their_links", keptRowsKeepTheirLinks};
  const telar::testing::Case case_session_asks_for_rows_beyond_the_screen{"scroll.session_asks_for_rows_beyond_the_screen", sessionAsksForRowsBeyondTheScreen};
  const telar::testing::Case case_folded_blocks_hide_their_output{"scroll.folded_blocks_hide_their_output", foldedBlocksHideTheirOutput};

}
