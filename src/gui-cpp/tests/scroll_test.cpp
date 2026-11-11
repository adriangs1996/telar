#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/memory.hpp"
#include "../input/scroll_motion.hpp"
#include "../terminal/fold_map.hpp"
#include "assertions.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <string>
#include <vector>

import telar.gui.tests.session_fixture;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.terminal.screen;
import telar.gui.links.cell_links;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

constexpr std::int64_t millisecond = 1'000'000;

ScrollTime at(std::int64_t milliseconds) {
  return {.nanoseconds = milliseconds * millisecond};
}

// Advances `motion` frame by frame at 120 Hz until it rests; how many frames it took.
std::size_t settle(ScrollMotion &motion, ScrollTime &now) {
  constexpr std::int64_t frame = 8'333'333;
  constexpr std::size_t most_frames = 1000;
  std::size_t frames = 0;
  while (motion.advance(now = {.nanoseconds = now.nanoseconds + frame})) {
    ++frames;
    require(frames < most_frames, "a motion must come to rest");
  }
  return frames;
}

void wheelEasesToItsTarget() {
  constexpr double limit = 1000;
  constexpr double start = 500;
  constexpr double notch = -66;
  constexpr double target = start + (2 * notch);
  constexpr double far = -10'000;
  constexpr std::size_t fewest_frames = 3;
  ScrollMotion motion;
  motion.setLimit(limit);
  motion.place(start);
  auto now = at(0);
  motion.wheel(notch, now);
  motion.wheel(notch, now);
  require(motion.destination() == target, "notches add to where the last ones were going");
  const auto frames = settle(motion, now);
  require(frames > fewest_frames && motion.position() == target && !motion.moving(), "a notch eases over several frames to its target");
  motion.wheel(far, now);
  settle(motion, now);
  require(motion.position() == 0, "a wheel stops at the top");
}

void precisePixelsFollowOneToOne() {
  constexpr double limit = 1000;
  constexpr double start = 100;
  constexpr double down = 3.5;
  constexpr double upward = -1.25;
  constexpr double tolerance = 1e-9;
  constexpr std::int64_t second_ms = 8;
  constexpr std::int64_t frame_ms = 16;
  ScrollMotion motion;
  motion.setLimit(limit);
  motion.place(start);
  motion.follow(down, at(0));
  motion.follow(upward, at(second_ms));
  require(std::abs(motion.position() - (start + down + upward)) < tolerance, "a trackpad's pixels move the rows one to one");
  require(!motion.advance(at(frame_ms)), "a followed gesture needs no frames of its own");
  motion.settle();
  require(!motion.moving(), "a gesture the platform continues ends without a fling");
}

void releaseFlings() {
  constexpr double limit = 100'000;
  constexpr double start = 1000;
  constexpr double step_pixels = 20;
  constexpr std::int64_t steps = 6;
  constexpr std::int64_t step_ms = 8;
  constexpr std::int64_t later_ms = 1000;
  constexpr std::int64_t rested_ms = 1200;
  ScrollMotion motion;
  motion.setLimit(limit);
  motion.place(start);
  for (std::int64_t step = 0; step < steps; ++step) {
    motion.follow(step_pixels, at(step * step_ms));
  }
  const auto lifted = at(steps * step_ms);
  motion.release(lifted);
  require(motion.moving() && motion.destination() > motion.position(), "a fast gesture flings on");
  const auto left = motion.position();
  auto now = lifted;
  settle(motion, now);
  require(motion.position() > left, "the fling carries the rows past where the finger left them");

  motion.place(start);
  motion.follow(step_pixels, at(later_ms));
  motion.release(at(rested_ms));
  require(!motion.moving(), "a gesture that rested before it ended does not fling");
}

void glidesJumpCloseFirst() {
  constexpr double limit = 100'000;
  constexpr double viewport = 400;
  constexpr double target = 50'000;
  constexpr double approach = target - (1.5 * viewport);
  constexpr std::int64_t partway_ms = 100;
  constexpr double end = 1000;
  constexpr double grown = 1200;
  constexpr std::int64_t growth_ms = 50;
  ScrollMotion motion;
  motion.setLimit(limit);
  motion.place(0);
  motion.glide(target, at(0), viewport);
  require(motion.position() == approach, "a far glide starts a view and a half before its target");
  motion.advance(at(partway_ms));
  require(motion.position() > approach && motion.position() < target, "a glide eases toward its target");
  auto now = at(partway_ms);
  settle(motion, now);
  require(motion.position() == target, "a glide ends on its target");

  motion.setLimit(end);
  motion.place(0);
  motion.glideToEnd(at(0), viewport);
  motion.advance(at(growth_ms));
  motion.setLimit(grown);
  require(motion.towardEnd() && motion.destination() == grown, "a glide to the end follows the end as it grows");
  now = at(growth_ms);
  settle(motion, now);
  require(motion.position() == grown, "a glide to the end arrives at the latest end");
}

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
  FoldMap<> folds;
  require(folds.display(any_row) == any_row && folds.row(any_row) == any_row, "without folds rows are their own display index");
  const std::array<FoldMap<>::Span, 3> spans{{{.first = later_fold, .count = later_rows}, {.first = first_fold, .count = fold_rows}, {.first = overlapping, .count = fold_rows}}};
  folds.assign(spans);
  require(folds.spans().size() == 2 && folds.spans()[0].first == first_fold && folds.spans()[0].count == joined_rows, "overlapping folds join, in order");
  require(folds.hides(first_fold) && folds.hides(after_first - 1) && !folds.hides(after_first) && !folds.hides(first_fold - 1), "a fold hides its rows only");
  require(folds.display(first_fold - 1) == first_fold - 1 && folds.display(after_first) == first_fold && folds.display(after_later) == after_later - joined_rows - later_rows, "shown rows count without the hidden ones above");
  require(folds.display(overlapping) == first_fold, "a hidden row takes the index of the first shown row under its fold");
  for (std::uint64_t index = 0; index < indexes; ++index) {
    const auto row = folds.row(index);
    require(!folds.hides(row) && folds.display(row) == index, "a display index names one shown row and back");
  }
  require(folds.shownRows(total) == total - joined_rows - later_rows, "the shown rows of a scrollback leave the hidden out");
}

// A reply carrying `rows` rows of one cell, "a", "b", ... from stable row `from`.
struct RowsReply {
  static constexpr std::size_t encoded_capacity = 1024;
  static constexpr std::size_t letter_count = 26;

  std::vector<Cell> cells;
  std::array<Byte, encoded_capacity> encoded{};
  std::vector<Byte> flags;
  std::array<Byte, letter_count> letters{};
  PaneRows reply{};

  RowsReply(PaneRows header, std::uint16_t rows) {
    for (std::size_t index = 0; index < letters.size(); ++index) {
      letters[index] = static_cast<Byte>('a' + index);
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
    reply.cells = CellRunCodec::encode(cells, encoded);
  }
};

void rowCacheKeepsRowsByStableNumber() {
  constexpr std::uint64_t generation = 3;
  constexpr std::uint64_t request = 7;
  constexpr std::uint64_t from = 100;
  constexpr std::uint16_t count = 4;
  constexpr std::uint64_t third = from + 2;
  SystemAllocator memory;
  RowCache<SystemAllocator> cache{memory};
  cache.number(generation);
  require(cache.empty() && !cache.find(0), "a cache holds nothing before its first rows");
  cache.ask(request, from, count);
  require(!cache.missing(from, from + count - 1) && cache.missing(from, from + count) == from + count, "rows asked for are not missing");
  const RowsReply reply{{.request_id = request, .generation = generation, .from = from}, count};
  require(cache.store(reply.reply, 1) && !cache.full(), "a reply of the cache's generation is kept and settles its request");
  const auto row = cache.find(third);
  require(row && row->cells.size() == 1 && row->cells.front().utf8() == "c", "a row is found by its stable number");
  require(!cache.find(third + RowCache<SystemAllocator>::slot_count), "a slot answers only for the row it holds");
  const RowsReply stale{{.request_id = request + 1, .generation = generation - 1, .from = from}, 1};
  require(!cache.store(stale.reply, 1), "rows of another generation are not kept");
  cache.number(generation + 1);
  require(!cache.find(third), "a new generation forgets the rows numbered by the old one");
  cache.release();
  require(cache.empty(), "a released cache gives its slots back");
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
  constexpr std::array<Byte, 1> letter{'x'};
  const std::vector<Cell> cells(static_cast<std::size_t>(columns) * rows, Cell{.text = letter});
  std::array<Byte, RowsReply::encoded_capacity> encoded{};
  const std::array<Byte, rows> flags{0, static_cast<Byte>(RowFlag::hyperlinks)};
  const std::array links{MetadataLink{.offset = 0, .len = static_cast<std::uint16_t>(uri.size())}};
  const std::array runs{MetadataRun{.start = columns + linked_column, .len = linked_cells, .link_index = 0}};
  const auto uri_bytes = byteView(uri);
  const PaneRows reply{.request_id = 1, .pane_id = 1, .generation = generation, .from = from, .cols = columns, .rows = rows, .text_metadata = TextMetadata{.row_flags = flags, .links = links, .runs = runs, .uris = uri_bytes}, .cells = CellRunCodec::encode(cells, encoded)};
  SystemAllocator memory;
  RowCache<SystemAllocator> cache{memory};
  cache.number(generation);
  require(cache.store(reply, columns), "rows with links are kept");
  std::string kept;
  std::uint16_t kept_column = 0;
  cache.links(from + 1, [&](const RowCache<SystemAllocator>::LinkView &link) {
    kept.assign(link.uri);
    kept_column = link.column;
    require(link.length == linked_cells, "a kept link covers its cells");
  });
  require(kept == uri && kept_column == linked_column, "a kept row keeps its link and target");
  bool none = true;
  cache.links(from, [&](const RowCache<SystemAllocator>::LinkView &) { none = false; });
  require(none, "a row without links has none");

  // The second kept row drawn first, as a folded view may draw it.
  Screen<SystemAllocator> drawn{memory};
  const auto row = cache.find(from + 1);
  const std::array spans{row->cells, std::span<const CellValue>{}};
  const std::array<Byte, rows> drawn_flags{row->flags, 0};
  const std::array drawn_runs{MetadataRun{.start = linked_column, .len = linked_cells, .link_index = 0}};
  drawn.compose(columns, spans, drawn_flags, TextMetadata{.row_flags = drawn_flags, .links = links, .runs = drawn_runs, .uris = uri_bytes});
  require(drawn.rows() == rows && drawn.scroll().offset == 0 && drawn.linkAt(linked_column) == uri, "a composed screen holds its rows' links");
  const auto found = CellLinks::resolve(drawn, CellPosition{.x = linked_column, .y = 0});
  require(found && found->start.x == linked_column && found->start.y == 0, "a link on a composed screen resolves where it is drawn");
}

void sessionAsksForRowsBeyondTheScreen() {
  constexpr std::uint32_t total = 1000;
  constexpr std::uint64_t generation = 5;
  constexpr std::uint64_t trimmed = 40;
  constexpr std::uint64_t dropped = 12;
  constexpr std::uint64_t first = 500;
  constexpr std::uint64_t last = 700;
  constexpr std::uint64_t second_from = first + RowCache<SystemAllocator>::request_rows;
  constexpr std::uint16_t kept = 3;
  SystemAllocator memory;
  Transport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  const FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = total, .offset = total - 1}};
  deliverSingleCell(client, frame);
  client.requestRows(1, 0, first);
  require(transport.count(ClientTag::read_pane_rows) == 0, "rows are not asked for before the runtime numbers them");
  deliver(client, PaneScrollback{.pane_id = 1, .generation = generation, .trimmed = trimmed});
  client.requestRows(1, first, last);
  const auto asked = transport.last<ReadPaneRows>();
  require(transport.count(ClientTag::read_pane_rows) == 2 && asked.from == second_from && asked.count == last - second_from + 1, "rows are asked for in bounded requests");
  client.requestRows(1, first, last);
  require(transport.count(ClientTag::read_pane_rows) == 2, "rows already asked for are not asked for again");
  const RowsReply reply{{.request_id = asked.request_id, .generation = generation, .from = asked.from}, kept};
  deliver(client, reply.reply);
  require(client.findPane(1)->rows.find(asked.from + 1).has_value(), "the reply's rows are kept");
  deliver(client, PaneScrollback{.pane_id = 1, .generation = generation, .trimmed = trimmed + dropped});
  require(client.takeDroppedRows(1) == dropped && client.takeDroppedRows(1) == 0, "the view learns how many rows the scrollback dropped, once");

  Transport legacy_transport;
  Session legacy{memory, legacy_transport};
  legacy.connected(1, false);
  require(!legacy.readsRows(), "a runtime without scrollback rows is not asked for them");
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
  Session client{memory, transport};
  openFirstPane(client, transport);
  const FrameBody frame{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = total, .offset = total - 1}};
  deliverSingleCell(client, frame);
  deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = trimmed});
  const auto blocks_at = [](std::uint32_t shift) {
    return std::array{CommandBlock{.row = first_row - shift, .rows = first_rows, .state = CommandBlockState::succeeded, .command = "ls"}, CommandBlock{.row = second_row - shift, .rows = 1, .state = CommandBlockState::failed, .status = 1, .command = "make"}, CommandBlock{.row = third_row - shift, .rows = 1, .state = CommandBlockState::running, .command = "tail"}};
  };
  const auto blocks = blocks_at(0);
  deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
  client.fold(1, 0, true);
  const auto &pane = *client.findPane(1);
  const auto output = first_row + first_rows;
  require(client.folded(1, 0) && pane.folds.hides(output) && pane.folds.hides(second_row - 1) && !pane.folds.hides(second_row) && !pane.folds.hides(output - 1), "a fold hides the rows between its prompt and the next");
  require(client.takeFoldChange() && !client.takeFoldChange(), "a fold change is reported once");
  client.foldAll(1, true);
  require(client.folded(1, 1) && !client.folded(1, 2), "folding all leaves the running command open");
  deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = trimmed + dropped});
  const auto moved = blocks_at(dropped);
  deliver(client, PaneBlocks{.pane_id = 1, .blocks = moved});
  require(client.folded(1, 0) && client.folded(1, 1) && pane.folds.hides(output - dropped) && !pane.folds.hides(second_row - dropped), "folds stay with their blocks when the scrollback drops rows above them");
  deliver(client, PaneScrollback{.pane_id = 1, .generation = 2, .trimmed = 0});
  deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
  require(client.folded(1, 0) && client.folded(1, 1) && !client.folded(1, 2), "renumbered rows keep the folds by block order");
  client.foldAll(1, false);
  require(!client.folded(1, 0) && pane.folds.empty(), "unfolding all shows every row");
}

}

int main() {
  try {
    wheelEasesToItsTarget();
    precisePixelsFollowOneToOne();
    releaseFlings();
    glidesJumpCloseFirst();
    foldsCountShownRows();
    rowCacheKeepsRowsByStableNumber();
    keptRowsKeepTheirLinks();
    sessionAsksForRowsBeyondTheScreen();
    foldedBlocksHideTheirOutput();
    std::puts("gui-scroll: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-scroll: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
