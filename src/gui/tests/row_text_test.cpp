#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/memory.hpp"
#include "../platform/font.h"
#include "../terminal/screen.hpp"
#include "assertions.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <freetype/freetype.h>
#include <ghostty/vt/unicode.h>
#include <hb.h>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <type_traits>
#include <utility>
#include <vector>

#include "core/memory.hpp"
#include "terminal/screen.hpp"

import telar.gui.tests.allocation_gate;
import telar.gui.tests.font_fixture;
import telar.gui.fonts.face;
import telar.gui.fonts.row_text_layout;
import telar.gui.fonts.text_runs;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::fonts;
  using namespace telar::gui::test;

  constexpr std::size_t columns = TextRuns<telar::ConcurrentMemory>::maximum_cells;
  constexpr std::uint16_t pixel_height = 15;
  constexpr std::uint16_t cell_width = 9;

  std::array<CellValue, columns> sourceCells() {
    constexpr std::string_view programming = "=-><=!";
    std::array<CellValue, columns> cells;

    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells[index].text[0] = static_cast<unsigned char>(programming[index % programming.size()]);
    }

    return cells;
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
        require(!layout.glyphs().empty(), "an allocation-free cursor transition must retain visible glyphs");
        require(budget.liveBytes() == retained_bytes, "warm row storage must retain its allocation budget");
      }
    }

    require(budget.liveBytes() == 0, "row layout must release every allocator-owned buffer");
  }

  void fontAndGridChangesRetireCachedPositions(FontFixture<telar::ConcurrentMemory>& fonts, FontFixture<telar::ConcurrentMemory>& alternate) {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    RowTextLayout layout{memory};
    std::array<CellValue, 2> cells;

    cells[0].text[0] = 'W';
    cells[1].text[0] = 'W';
    constexpr std::uint16_t larger_height = 39;
    constexpr std::uint16_t wider_cell = 33;

    for (auto* source : {&fonts, &alternate, &fonts}) {
      for (const auto height : {pixel_height, larger_height, pixel_height}) {
        for (const auto width : {cell_width, wider_cell}) {
          layout.shape(*source, cells, {.pixel_height = height, .cell_width = width});
          const auto expected = source->face(FontRole::primary).shape("W", height).glyph(0);

          require(layout.glyphs().front().x_advance == expected.x_advance, "cached glyph advances must belong to the current face and pixel height");
          require(std::cmp_equal(layout.spans().back().offset, width), "cell placement must use the current physical grid");
        }
      }
    }
  }

  // A short cell outside ASCII lays out the same whether the row shapes it or recalls what it kept
  // of it: one glyph of the primary face, a combining pair, a ligature's letter, a face's fallback.
  void keptClustersLayOutAsShaped(FontFixture<telar::ConcurrentMemory>& fonts) {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    RowTextLayout layout{memory};
    constexpr std::array<std::string_view, 9> texts{"á", "ñ", "ß", "λ", "ж", "e\u0301", "→", "漢", "\U0001F600"};
    std::array<CellValue, texts.size() * 2> cells;

    for (std::size_t column = 0; column < cells.size(); ++column) {
      const auto text = texts[column % texts.size()];

      std::ranges::copy(text, cells[column].text.begin());
      cells[column].length = static_cast<telar::Byte>(text.size());
    }

    const RowTextRequest request{.pixel_height = pixel_height, .cell_width = cell_width};
    const auto snapshot = [&] {
      std::vector<std::tuple<std::size_t, std::size_t, int, std::int32_t, std::uint32_t>> spans;

      for (const auto& span : layout.spans()) {
        spans.emplace_back(span.first, span.count, static_cast<int>(span.role), span.offset, span.columns);
      }

      return std::pair{std::vector<ShapedGlyph>{layout.glyphs().begin(), layout.glyphs().end()}, spans};
    };

    layout.shape(fonts, cells, request);
    const auto shaped = snapshot();

    require(!shaped.first.empty(), "the row shapes its cells");
    layout.shape(fonts, cells, request);
    require(snapshot() == shaped, "a row recalled from what it kept lays out as it was shaped");
    layout.resetFont();
    layout.shape(fonts, cells, request);
    require(snapshot() == shaped, "a row shaped again after a font change lays out the same");

    // What a row kept belongs to the pixel height it was shaped at.
    for (const std::uint16_t height : {std::uint16_t{39}, pixel_height, std::uint16_t{39}}) {
      const RowTextRequest sized{.pixel_height = height, .cell_width = cell_width};

      layout.shape(fonts, cells, sized);
      const auto kept = snapshot();
      RowTextLayout fresh{memory};

      fresh.shape(fonts, cells, sized);
      require(kept.first == std::vector<ShapedGlyph>{fresh.glyphs().begin(), fresh.glyphs().end()}, "a kept cell follows the row's pixel height");
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

    require(failed, "row buffers must honor the injected allocator");
    gate.permit(std::nullopt);
    layout.shape(fonts, cells, {.pixel_height = pixel_height, .cell_width = cell_width});
    require(layout.spans().size() == cells.size(), "a failed first allocation must leave the layout reusable");
  }

}

int main(int argc, char** argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 2;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    SystemAllocator system;
    telar::MemoryAdapter adapter{system};
    telar::ConcurrentMemory& memory = adapter;
    const std::filesystem::path assets{arguments[1]};
    FontFixture fonts{memory, assets};
    FontFixture alternate{memory, assets, "IBMPlexSans-Regular.ttf"};

    storageIsReusedAcrossCursorAndSelectionChanges(fonts);
    fontAndGridChangesRetireCachedPositions(fonts, alternate);
    failedStorageCanBeRetried(fonts);
    keptClustersLayOutAsShaped(fonts);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
