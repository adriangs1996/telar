#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <limits>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <bit>
#include <ghostty/vt/unicode.h>
#include <cstring>
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.core.metrics;
import telar.gui.presentation.form_field_geometry;
import telar.gui.terminal.font_grid;
import telar.gui.text.bounded_editor;

namespace {

using namespace telar::gui;

constexpr std::size_t editor_capacity = 512;
using Editor = BoundedEditor<editor_capacity>;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void replacementsOwnAliasedInputAndRejectAtomically() {
  constexpr std::size_t capacity = 8;
  BoundedEditor<capacity> editor;
  require(editor.setText("abcdef"), "valid bounded initialization must succeed");
  require(editor.replace(0, 1, editor.text().substr(2, 3)), "replacement must accept its own borrowed text");
  require(editor.text() == "cdebcdef", "tail movement must not overwrite aliased input");
  editor.selectRange(1, 4);
  const auto before = editor;
  require(!editor.replace(0, 0, "overflow"), "overflow must reject the complete edit");
  require(!editor.replace(0, 1, "\xff"), "replacement must reject invalid UTF-8");
  require(!editor.selectRange(0, capacity + 1), "selection must reject offsets beyond the field");
  require(!editor.setText("oversized"), "initialization must reject oversized text");
  require(editor.text() == before.text() && editor.head() == before.head() && editor.anchor() == before.anchor() && editor.scroll() == before.scroll(), "rejected edits must preserve text, selection and scroll");
}

void editsKeepGraphemesWhole() {
  Editor editor;
  require(editor.setText("a👩‍💻é"), "Unicode input must fit");
  editor.backspace();
  require(editor.text() == "a👩‍💻", "backspace must remove a combining cluster");
  editor.moveLeft(true);
  require(editor.selected() == "👩‍💻", "extended movement must select a joined emoji");
  editor.insert("中");
  require(editor.text() == "a中", "insertion must replace the selected cluster");
  editor.home(false);
  editor.deleteForward();
  require(editor.text() == "中", "forward deletion must remove one cluster");
  require(!editor.selectRange(0, 1), "selection must reject offsets inside a scalar");
}

void fit(Editor &editor, std::uint16_t width) {
  const auto view = editor.view(width);
  require(width == 0 ? view.cursor == 0 : view.cursor < width, "the visible cursor must remain inside its columns");
  telar::validateUtf8(view.text);
}

void staleScrollCannotCrossTheCursor() {
  constexpr std::uint16_t wide_columns = 16;
  Editor editor;
  require(editor.setText("🇪🇸👩‍💻á\tá"), "the original crash fixture must initialize");
  fit(editor, 1);
  editor.insert("é");
  fit(editor, wide_columns);
  editor.moveWordLeft(false);
  fit(editor, 2);
  editor.moveRight(true);
  fit(editor, wide_columns);
  editor.clearSelection();
  fit(editor, 2);
  editor.moveRight(true);
  fit(editor, 1);
  editor.insert("👩‍💻");
  fit(editor, 1);
  fit(editor, 0);
}

void formGeometryKeepsPhysicalCellsAndInsets() {
  constexpr Rect bounds{.width = 200, .height = 52};
  constexpr FontGrid grid{.width = 8, .height = 20, .pixel_height = 13, .baseline = 14};
  constexpr ChromeMetrics chrome;
  const auto geometry = FormFieldGeometry::derive(bounds, chrome, grid);
  constexpr Rect expected_content{.x = 12, .y = 16, .width = 176, .height = 20};
  constexpr Rect expected_caret{.x = 180, .y = 16, .width = 1, .height = 20};
  constexpr std::uint16_t expected_columns = 22;
  require(geometry.content == expected_content && geometry.columns == expected_columns, "form content must retain the original body grid and insets");
  constexpr std::uint16_t outside_column = 100;
  require(geometry.caret(outside_column) == expected_caret, "the insertion caret must clamp to the last visible column");
  constexpr Rect empty_bounds;
  const auto empty = FormFieldGeometry::derive(empty_bounds, chrome, grid);
  require(empty.columns == 0 && empty.caret(0).empty(), "empty form controls must produce no cursor");
}

}

int main() {
  try {
    replacementsOwnAliasedInputAndRejectAtomically();
    editsKeepGraphemesWhole();
    staleScrollCannotCrossTheCursor();
    formGeometryKeepsPhysicalCellsAndInsets();
    std::puts("gui-editor: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-editor: " << error.what() << '\n';

    return 1;
  }
}
