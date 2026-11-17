#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.base.text.utf8;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  constexpr std::size_t editor_capacity = 512;
  using Editor = BoundedEditor<editor_capacity>;

  void replacementsOwnAliasedInputAndRejectAtomically() {
    constexpr auto capacity = Editor::capacity;
    // The replacement below fills the field exactly, so that any further byte overflows it.
    const std::string padding(capacity - std::string_view{"cdebcdef"}.size(), 'x');
    Editor editor;

    check(editor.setText("abcdef" + padding), "valid bounded initialization must succeed");
    check(editor.replace(0, 1, editor.text().substr(2, 3)), "replacement must accept its own borrowed text");
    check(editor.text() == "cdebcdef" + padding, "tail movement must not overwrite aliased input");
    editor.selectRange(1, 4);
    const auto before = editor;

    check(!editor.replace(0, 0, "overflow"), "overflow must reject the complete edit");
    check(!editor.replace(0, 1, "\xff"), "replacement must reject invalid UTF-8");
    check(!editor.selectRange(0, capacity + 1), "selection must reject offsets beyond the field");
    check(!editor.setText(std::string(capacity + 1, 'x')), "initialization must reject oversized text");
    check(editor.text() == before.text() && editor.head() == before.head() && editor.anchor() == before.anchor() && editor.scroll() == before.scroll(), "rejected edits must preserve text, selection and scroll");
  }

  void editsKeepGraphemesWhole() {
    Editor editor;

    check(editor.setText("a👩‍💻é"), "Unicode input must fit");
    editor.backspace();
    check(editor.text() == "a👩‍💻", "backspace must remove a combining cluster");
    editor.moveLeft(true);
    check(editor.selected() == "👩‍💻", "extended movement must select a joined emoji");
    editor.insert("中");
    check(editor.text() == "a中", "insertion must replace the selected cluster");
    editor.home(false);
    editor.deleteForward();
    check(editor.text() == "中", "forward deletion must remove one cluster");
    check(!editor.selectRange(0, 1), "selection must reject offsets inside a scalar");
  }

  void fit(Editor& editor, std::uint16_t width) {
    const auto view = editor.view(width);

    check(width == 0 ? view.cursor == 0 : view.cursor < width, "the visible cursor must remain inside its columns");
    telar::validateUtf8(view.text);
  }

  void staleScrollCannotCrossTheCursor() {
    constexpr std::uint16_t wide_columns = 16;
    Editor editor;

    check(editor.setText("🇪🇸👩‍💻á\tá"), "the original crash fixture must initialize");
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

    check(geometry.content == expected_content && geometry.columns == expected_columns, "form content must retain the original body grid and insets");
    constexpr std::uint16_t outside_column = 100;

    check(geometry.caret(outside_column) == expected_caret, "the insertion caret must clamp to the last visible column");
    constexpr Rect empty_bounds;
    const auto empty = FormFieldGeometry::derive(empty_bounds, chrome, grid);

    check(empty.columns == 0 && empty.caret(0).empty(), "empty form controls must produce no cursor");
  }

  const telar::testing::Case case_replacements_own_aliased_input_and_reject_atomically{"editor.replacements_own_aliased_input_and_reject_atomically", replacementsOwnAliasedInputAndRejectAtomically};
  const telar::testing::Case case_edits_keep_graphemes_whole{"editor.edits_keep_graphemes_whole", editsKeepGraphemesWhole};
  const telar::testing::Case case_stale_scroll_cannot_cross_the_cursor{"editor.stale_scroll_cannot_cross_the_cursor", staleScrollCannotCrossTheCursor};
  const telar::testing::Case case_form_geometry_keeps_physical_cells_and_insets{"editor.form_geometry_keeps_physical_cells_and_insets", formGeometryKeepsPhysicalCellsAndInsets};

}
