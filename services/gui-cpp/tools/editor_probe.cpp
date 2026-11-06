#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <algorithm>
#include <ghostty/vt/unicode.h>
#include <cstring>
#include <limits>
#include <cstdio>
#include <exception>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.text.bounded_editor;

namespace {

using namespace telar::gui;

constexpr std::size_t editor_capacity = 512;
using Editor = BoundedEditor<editor_capacity>;

enum class Operation : std::uint8_t {
  reset,
  select,
  replace,
  insert,
  backspace,
  delete_forward,
  left,
  right,
  home,
  end,
  word_left,
  word_right,
  select_all,
  deselect,
  inspect,
};

struct Request {
  Operation operation = Operation::reset;
  std::uint16_t width = 0;
  std::uint16_t first = 0;
  std::uint16_t last = 0;
  bool extend = false;
  bool snapshot = false;
  std::string_view text;
};

bool apply(Editor &editor, const Request &request) {
  switch (request.operation) {
  case Operation::reset:
    editor.setText(request.text);
    break;
  case Operation::select:
    return editor.selectRange(request.first, request.last);
  case Operation::replace:
    return editor.replace(request.first, request.last, request.text);
  case Operation::insert:
    editor.insert(request.text);
    break;
  case Operation::backspace:
    editor.backspace();
    break;
  case Operation::delete_forward:
    editor.deleteForward();
    break;
  case Operation::left:
    editor.moveLeft(request.extend);
    break;
  case Operation::right:
    editor.moveRight(request.extend);
    break;
  case Operation::home:
    editor.home(request.extend);
    break;
  case Operation::end:
    editor.end(request.extend);
    break;
  case Operation::word_left:
    editor.moveWordLeft(request.extend);
    break;
  case Operation::word_right:
    editor.moveWordRight(request.extend);
    break;
  case Operation::select_all:
    editor.selectAll();
    break;
  case Operation::deselect:
    editor.clearSelection();
    break;
  case Operation::inspect:
    break;
  }

  return false;
}

void frame(Editor &editor, Operation operation, SystemAllocator &memory) {
  Request request{.operation = operation, .text = {}};
  request.width = probe::read<std::uint16_t>();
  request.first = probe::read<std::uint16_t>();
  request.last = probe::read<std::uint16_t>();
  constexpr std::uint8_t extend_flag = 1;
  constexpr std::uint8_t snapshot_flag = 2;
  const auto flags = probe::read<std::uint8_t>();
  request.extend = (flags & extend_flag) != 0;
  request.snapshot = (flags & snapshot_flag) != 0;
  const auto text = probe::readText(memory);
  request.text = text;
  const auto changed = apply(editor, request);
  Editor display;
  display.setText(editor.text());
  display.selectRange(editor.anchor(), editor.head());
  auto &painted = request.snapshot ? display : editor;
  const auto view = painted.view(request.width);
  probe::write(static_cast<std::uint8_t>(changed));
  probe::writeText(editor.text());
  probe::write(static_cast<std::uint16_t>(editor.head()));
  probe::write(static_cast<std::uint16_t>(editor.anchor()));
  probe::write(static_cast<std::uint16_t>(painted.scroll()));
  probe::writeText(editor.selected());
  probe::writeText(view.text);
  probe::write(view.cursor);
  probe::write(static_cast<std::uint8_t>(view.selection.has_value()));
  probe::write(view.selection.value_or(EditorColumns{}).first);
  probe::write(view.selection.value_or(EditorColumns{}).last);
  probe::write(static_cast<std::uint8_t>(view.clipped_left));
  probe::write(static_cast<std::uint8_t>(view.clipped_right));
}

}

int main() {
  try {
    telar::gui::SystemAllocator memory;
    Editor editor;
    for (auto operation = std::fgetc(stdin); operation != EOF; operation = std::fgetc(stdin)) {
      frame(editor, static_cast<Operation>(operation), memory);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
