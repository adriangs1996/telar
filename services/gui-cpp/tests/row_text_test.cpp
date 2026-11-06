#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "allocation_gate.hpp"
#include "assertions.hpp"
#include "../core/memory.hpp"
#include "font_fixture.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <string_view>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <bit>
#include "../terminal/screen.hpp"
#include <ghostty/vt/unicode.h>
#include <exception>
#include <filesystem>
#include <iostream>
#include <new>

#include "core/memory.hpp"
#include "terminal/screen.hpp"


import telar.gui.fonts.face;
import telar.gui.fonts.row_text_layout;
import telar.gui.terminal.copy_mode;

namespace {

using namespace telar::gui;
using namespace telar::gui::fonts;
using namespace telar::gui::test;

constexpr std::size_t columns = TextRuns<SystemAllocator>::maximum_cells;
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

void storageIsReusedAcrossCursorAndSelectionChanges(FontFixture<SystemAllocator> &fonts) {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    RowTextLayout layout{memory};
    const auto cells = sourceCells();
    RowTextRequest request{.pixel_height = pixel_height, .cell_width = cell_width};
    layout.shape(fonts, cells, request);
    const auto retained_bytes = budget.liveBytes();
    memory.permit(0);
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

void fontAndGridChangesRetireCachedPositions(FontFixture<SystemAllocator> &fonts, FontFixture<SystemAllocator> &alternate) {
  SystemAllocator memory;
  RowTextLayout layout{memory};
  std::array<CellValue, 2> cells;
  cells[0].text[0] = 'W';
  cells[1].text[0] = 'W';
  constexpr std::uint16_t larger_height = 39;
  constexpr std::uint16_t wider_cell = 33;
  for (auto *source : {&fonts, &alternate, &fonts}) {
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

void failedStorageCanBeRetried(FontFixture<SystemAllocator> &fonts) {
  SystemAllocator upstream;
  AllocationGate memory{upstream};
  RowTextLayout layout{memory};
  const auto cells = sourceCells();
  memory.permit(0);
  bool failed = false;
  try {
    layout.shape(fonts, cells, {.pixel_height = pixel_height, .cell_width = cell_width});
  } catch (const std::bad_alloc &) {
    failed = true;
  }

  require(failed, "row buffers must honor the injected allocator");
  memory.permit(std::nullopt);
  layout.shape(fonts, cells, {.pixel_height = pixel_height, .cell_width = cell_width});
  require(layout.spans().size() == cells.size(), "a failed first allocation must leave the layout reusable");
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 2;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    SystemAllocator memory;
    const std::filesystem::path assets{arguments[1]};
    FontFixture fonts{memory, assets};
    FontFixture alternate{memory, assets, "IBMPlexSans-Regular.ttf"};
    storageIsReusedAcrossCursorAndSelectionChanges(fonts);
    fontAndGridChangesRetireCachedPositions(fonts, alternate);
    failedStorageCanBeRetried(fonts);
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
