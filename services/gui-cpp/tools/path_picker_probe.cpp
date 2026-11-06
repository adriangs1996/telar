#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "../core/memory.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <span>
#include <optional>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "../terminal/cell_position.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstdio>
#include <exception>

#include "core/memory.hpp"
#include "terminal/cell_position.hpp"


import telar.gui.core.unicode_scalar;
import telar.gui.paths.label;
import telar.gui.presentation.form_field_geometry;

namespace {

using namespace telar::gui;
using namespace telar::gui::probe;

void quoteCase(SystemAllocator &memory) {
  const auto word = readText(memory);
  const auto result = PathInsertion::quote(word);
  write(static_cast<std::uint8_t>(result.has_value()));
  if (result) {
    writeText(result->view());
  }
}

void joinCase(SystemAllocator &memory) {
  const auto root = readText(memory);
  const auto relative = readText(memory);
  const auto anchor = readText(memory);
  const auto joined = PathInsertion::join({.root = root, .relative = relative});
  writeText(joined.view());
  const auto result = PathInsertion::relativeTo(anchor, joined.view());
  write(static_cast<std::uint8_t>(result.has_value()));
  if (result) {
    writeText(*result);
  }
}

void placementCase() {
  const auto x = read<std::uint16_t>();
  const auto y = read<std::uint16_t>();
  const auto width = read<std::uint16_t>();
  const auto height = read<std::uint16_t>();
  const CellRectangle host{.x = x, .y = y, .width = width, .height = height};
  std::optional<CellPosition> cursor;
  if (read<std::uint8_t>() != 0) {
    const auto column = read<std::uint16_t>();
    cursor = CellPosition{.x = column, .y = read<std::uint16_t>()};
  }

  const auto placement = PathPickerPlacement::forPage(host, cursor, read<std::uint16_t>());
  write(placement.area.x);
  write(placement.area.y);
  write(placement.area.width);
  write(placement.area.height);
  write(static_cast<std::uint8_t>(placement.flipped));
}

void labelCase(SystemAllocator &memory) {
  const auto path = readText(memory);
  const auto width = read<std::uint16_t>();
  const auto count = read<std::uint8_t>();
  std::array<std::uint16_t, PathPickerLimits::query_bytes> positions{};
  if (count > positions.size()) {
    throw std::length_error{"Too many probe highlights"};
  }

  for (auto &position : std::span{positions}.first(count)) {
    position = read<std::uint16_t>();
  }

  PathLabel label;
  label.layout(path, std::span{positions}.first(count), width);
  write(static_cast<std::uint8_t>(label.runs().size()));
  for (const auto &run : label.runs()) {
    write(static_cast<std::uint8_t>(run.tone));
    writeText(run.text);
  }
}

enum class Operation : std::uint8_t {
  quote = 1,
  join,
  placement,
  label,
};

}

int main() {
  try {
    SystemAllocator memory;
    int operation = 0;
    while ((operation = std::getchar()) != EOF) {
      switch (static_cast<Operation>(operation)) {
      case Operation::quote:
        quoteCase(memory);
        break;
      case Operation::join:
        joinCase(memory);
        break;
      case Operation::placement:
        placementCase();
        break;
      case Operation::label:
        labelCase(memory);
        break;
      default:
        throw std::runtime_error{"Unknown probe operation"};
      }
    }
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
