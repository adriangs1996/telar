#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <limits>
#include <new>
#include <optional>
#include <span>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

import telar.testing;
import telar.testing.test_memory;
import telar.wire.vocabulary;
import telar.gui.tests.allocation_gate;
import telar.gui.foundation.terminal;
import telar.gui.foundation.fonts;
import telar.gui.foundation.fonts.tests.font_fixture;
import telar.base.ds;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::fonts;
  using namespace telar::gui::test;
  using telar::gui::fonts::tests::font_fixture::FontFixture;
  using telar::testing::check;

  constexpr std::size_t columns = TextRuns<telar::ConcurrentMemory>::maximum_cells;
  constexpr std::uint16_t pixel_height = 15;
  constexpr std::uint16_t cell_width = 9;

  telar::ds::Array<CellValue, columns> sourceCells() {
    constexpr std::string_view programming = "=-><=!";
    telar::ds::Array<CellValue, columns> cells;

    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells.atMut(index).text.atMut(0) = static_cast<unsigned char>(programming[index % programming.size()]);
    }

    return cells;
  }

  using LaidOut = std::pair<std::vector<ShapedGlyph>, std::vector<std::tuple<std::size_t, std::size_t, int, std::int32_t, std::uint32_t>>>;

  // What a row laid out: its glyphs and its spans.
  LaidOut laidOut(const RowTextLayout<telar::ConcurrentMemory>& layout) {
    LaidOut result{{layout.glyphs().begin(), layout.glyphs().end()}, {}};

    for (const auto& span : layout.spans()) {
      result.second.emplace_back(span.first, span.count, static_cast<int>(span.role), span.offset, span.columns);
    }

    return result;
  }

  void storageIsReusedAcrossCursorAndSelectionChanges(FontFixture<telar::ConcurrentMemory>& fonts) {
    SystemAllocator upstream;
    BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
    AllocationGate gate{budget};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;

    {
      RowTextLayout layout{memory};
      const auto cells = sourceCells();
      RowTextRequest request{.pixel_height = pixel_height, .cell_width = cell_width};

      layout.shape(fonts, cells, request);
      const auto retained_bytes = budget.liveBytes();

      gate.permit(0);
      for (std::size_t column = 0; column < cells.size(); ++column) {
        request.cursor = column;
        request.selection = {.anchor = 0, .head = static_cast<int>(column)};
        layout.shape(fonts, cells, request);
        check(!layout.glyphs().empty(), "an allocation-free cursor transition must retain visible glyphs");
        check(budget.liveBytes() == retained_bytes, "warm row storage must retain its allocation budget");
      }
    }

    check(budget.liveBytes() == 0, "row layout must release every allocator-owned buffer");
  }

  void fontAndGridChangesRetireCachedPositions(FontFixture<telar::ConcurrentMemory>& fonts, FontFixture<telar::ConcurrentMemory>& alternate) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    RowTextLayout layout{memory};
    telar::ds::Array<CellValue, 2> cells;

    cells.atMut(0).text.atMut(0) = 'W';
    cells.atMut(1).text.atMut(0) = 'W';
    constexpr std::uint16_t larger_height = 39;
    constexpr std::uint16_t wider_cell = 33;

    for (auto* source : {&fonts, &alternate, &fonts}) {
      for (const auto height : {pixel_height, larger_height, pixel_height}) {
        for (const auto width : {cell_width, wider_cell}) {
          layout.shape(*source, cells, {.pixel_height = height, .cell_width = width});
          const auto expected = source->face(FontRole::primary).shape("W", height).glyph(0);

          check(layout.glyphs().front().x_advance == expected.x_advance, "cached glyph advances must belong to the current face and pixel height");
          check(std::cmp_equal(layout.spans().back().offset, width), "cell placement must use the current physical grid");
        }
      }
    }
  }

  // A short cell outside ASCII lays out the same whether the row shapes it or recalls what it kept
  // of it: one glyph of the primary face, a combining pair, a ligature's letter, a face's fallback.
  void keptClustersLayOutAsShaped(FontFixture<telar::ConcurrentMemory>& fonts) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    RowTextLayout layout{memory};
    constexpr telar::ds::Array<std::string_view, 9> texts{"á", "ñ", "ß", "λ", "ж", "e\u0301", "→", "漢", "\U0001F600"};
    telar::ds::Array<CellValue, texts.size() * 2> cells;

    for (std::size_t column = 0; column < cells.size(); ++column) {
      const auto text = texts[column % texts.size()];

      std::ranges::copy(text, cells.atMut(column).text.viewMut().begin());
      cells.atMut(column).length = static_cast<telar::Byte>(text.size());
    }

    const RowTextRequest request{.pixel_height = pixel_height, .cell_width = cell_width};

    layout.shape(fonts, cells, request);
    const auto shaped = laidOut(layout);

    check(!shaped.first.empty(), "the row shapes its cells");
    layout.shape(fonts, cells, request);
    check(laidOut(layout) == shaped, "a row recalled from what it kept lays out as it was shaped");
    layout.resetFont();
    layout.shape(fonts, cells, request);
    check(laidOut(layout) == shaped, "a row shaped again after a font change lays out the same");

    // What a row kept belongs to the pixel height it was shaped at.
    for (const std::uint16_t height : {std::uint16_t{39}, pixel_height, std::uint16_t{39}}) {
      const RowTextRequest sized{.pixel_height = height, .cell_width = cell_width};

      layout.shape(fonts, cells, sized);
      const auto kept = laidOut(layout);
      RowTextLayout fresh{memory};

      fresh.shape(fonts, cells, sized);
      check(kept.first == std::vector<ShapedGlyph>{fresh.glyphs().begin(), fresh.glyphs().end()}, "a kept cell follows the row's pixel height");
    }
  }

  // Telar Forma heals its texture through `calt`: a narrow letter beside a wide one gives up
  // the serif that faces it and the wide one is drawn wider, so the row shapes them together.
  void telarFormaHealsTextureAcrossCells() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    FontFixture fonts{memory, std::filesystem::path{TELAR_GUI_ASSETS_DIR}, "TelarForma-Regular.ttf"};
    RowTextLayout layout{memory};
    constexpr std::string_view text = "mia";
    telar::ds::Array<CellValue, text.size()> cells;

    for (std::size_t column = 0; column < cells.size(); ++column) {
      cells.atMut(column).text.atMut(0) = static_cast<unsigned char>(text[column]);
    }

    auto& face = fonts.face(FontRole::primary);
    const auto wide = face.shape("m", pixel_height).glyph(0);
    const auto narrow = face.shape("i", pixel_height).glyph(0);
    const auto plain = face.shape("a", pixel_height).glyph(0);
    RowTextRequest request{.pixel_height = pixel_height, .cell_width = cell_width};

    layout.shape(fonts, cells, request);
    check(layout.glyphs().size() == cells.size(), "each cell keeps one glyph");
    check(layout.glyphs()[0].index != wide.index && layout.glyphs()[1].index != narrow.index, "a wide letter and the narrow one beside it take their healed glyphs");
    check(layout.glyphs()[0].x_advance == wide.x_advance && layout.glyphs()[1].x_advance == narrow.x_advance, "a healed glyph keeps the cell's advance");
    check(layout.glyphs()[2].index == plain.index, "a letter that neither gives nor takes room keeps its glyph");

    // The cell under the cursor is drawn alone, so its neighbour has no one to heal with.
    request.cursor = 1;
    layout.shape(fonts, cells, request);
    check(layout.glyphs()[0].index == wide.index && layout.glyphs()[1].index == narrow.index, "the cell under the cursor and its neighbour take their own glyphs");
  }

  // A short run lays out the same whether the row asks the shaper or recalls what it kept of
  // the run. A row that has laid out every row before and a fresh one agree on ligatures, healed
  // letters, runs too long to keep and cells of more than one byte, through cursor moves and
  // pixel height changes, with a face that heals its texture and one that does not.
  void keptRunsLayOutAsShaped() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const std::filesystem::path assets{TELAR_GUI_ASSETS_DIR};
    constexpr std::string_view letters = "mwMWiltfjI1.,()[]{}=-><!:/|&*a e";
    constexpr std::string_view accented = "í";
    constexpr std::size_t rows = 600;
    constexpr std::size_t row_cells = 48;
    constexpr std::size_t rows_per_height = 150;
    constexpr std::uint16_t larger_height = 39;

    for (const auto* primary : {"JetBrainsMono-Regular.ttf", "TelarForma-Regular.ttf"}) {
      FontFixture fonts{memory, assets, primary};
      RowTextLayout warm{memory};
      std::uint32_t seed = 1;
      const auto next = [&seed] {
        constexpr std::uint32_t multiplier = 1664525;
        constexpr std::uint32_t increment = 1013904223;
        constexpr unsigned high_bits = 16;

        seed = (seed * multiplier) + increment;

        return seed >> high_bits;
      };

      for (std::size_t row = 0; row < rows; ++row) {
        telar::ds::Array<CellValue, row_cells> cells;

        for (auto& cell : cells.viewMut()) {
          const auto pick = next();
          const auto text = pick % (letters.size() + 1) == letters.size() ? accented : letters.substr(pick % (letters.size() + 1), 1);

          std::ranges::copy(text, cell.text.viewMut().begin());
          cell.length = static_cast<telar::Byte>(text.size());
        }

        RowTextRequest request{.pixel_height = (row / rows_per_height) % 2 == 0 ? pixel_height : larger_height, .cell_width = cell_width};
        if (row % 3 == 0) {
          request.cursor = next() % row_cells;
        }

        RowTextLayout fresh{memory};

        warm.shape(fonts, cells, request);
        fresh.shape(fonts, cells, request);
        check(laidOut(warm) == laidOut(fresh), "a row that kept runs lays out as one that shapes them all");
      }
    }
  }

  void failedStorageCanBeRetried(FontFixture<telar::ConcurrentMemory>& fonts) {
    SystemAllocator upstream;
    AllocationGate gate{upstream};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;
    RowTextLayout layout{memory};
    const auto cells = sourceCells();

    gate.permit(0);
    bool failed = false;

    try {
      layout.shape(fonts, cells, {.pixel_height = pixel_height, .cell_width = cell_width});
    } catch (const std::bad_alloc&) {
      failed = true;
    }

    check(failed, "row buffers must honor the injected allocator");
    gate.permit(telar::ds::none);
    layout.shape(fonts, cells, {.pixel_height = pixel_height, .cell_width = cell_width});
    check(layout.spans().size() == cells.size(), "a failed first allocation must leave the layout reusable");
  }

  // The fonts of the repository's assets, read into system memory for one case.
  template <void (*verify)(FontFixture<telar::ConcurrentMemory>&)>
  void withFonts() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    FontFixture fonts{memory, std::filesystem::path{TELAR_GUI_ASSETS_DIR}};

    verify(fonts);
  }

  void fontAndGridChanges() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const std::filesystem::path assets{TELAR_GUI_ASSETS_DIR};
    FontFixture fonts{memory, assets};
    FontFixture alternate{memory, assets, "IBMPlexSans-Regular.ttf"};

    fontAndGridChangesRetireCachedPositions(fonts, alternate);
  }

  const telar::testing::Case case_storage_is_reused_across_cursor_and_selection_changes{"row_text.storage_is_reused_across_cursor_and_selection_changes", withFonts<storageIsReusedAcrossCursorAndSelectionChanges>};
  const telar::testing::Case case_font_and_grid_changes_retire_cached_positions{"row_text.font_and_grid_changes_retire_cached_positions", fontAndGridChanges};
  const telar::testing::Case case_failed_storage_can_be_retried{"row_text.failed_storage_can_be_retried", withFonts<failedStorageCanBeRetried>};
  const telar::testing::Case case_kept_clusters_lay_out_as_shaped{"row_text.kept_clusters_lay_out_as_shaped", withFonts<keptClustersLayOutAsShaped>};
  const telar::testing::Case case_kept_runs_lay_out_as_shaped{"row_text.kept_runs_lay_out_as_shaped", keptRunsLayOutAsShaped};
  const telar::testing::Case case_telar_forma_heals_texture_across_cells{"row_text.telar_forma_heals_texture_across_cells", telarFormaHealsTextureAcrossCells};

}
