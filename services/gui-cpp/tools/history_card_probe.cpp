#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <bit>
#include <stdexcept>
#include <ghostty/vt/unicode.h>
#include <limits>
#include <concepts>
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include <cstdio>
#include <exception>
#include <iostream>

#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.presentation.history_meta_geometry;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.form_field_geometry;
import telar.gui.text.bounded_editor;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  wrap,
  card,
  command_line,
};

enum class Flag : std::uint8_t {
  agent = 1,
  has_time = 2,
};

float textWidth(std::string_view text, float cell_width) {
  GraphemeCursor cursor{text};
  std::uint32_t columns = 0;
  while (cursor.nextReplacingInvalid()) {
    columns += cursor.columns();
  }

  return static_cast<float>(columns) * cell_width;
}

void wrappedLines(SystemAllocator &memory) {
  const auto columns = probe::read<std::uint16_t>();
  const auto words = probe::read<std::uint8_t>() != 0;
  const auto text = probe::readText(memory);
  WrappedLines lines{text, columns, words};
  while (const auto line = lines.next()) {
    probe::write(std::uint8_t{1});
    probe::writeText(*line);
  }

  probe::write(std::uint8_t{0});
}

void card(SystemAllocator &memory) {
  const auto bounds = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  HistoryCardMetrics metrics;
  metrics.row_height = probe::read<float>();
  metrics.cell_width = static_cast<float>(probe::read<std::uint32_t>());
  metrics.cell_height = static_cast<float>(probe::read<std::uint32_t>());
  chrome.small = probe::read<std::uint16_t>();
  metrics.viewport_height = probe::read<float>();
  const auto time_width = probe::read<float>();
  const auto flags = probe::read<std::uint8_t>();
  const auto text = probe::readText(memory);
  const HistoryRowMeasurements measured{
      .time = time_width,
      .agent = (flags & static_cast<std::uint8_t>(Flag::agent)) != 0,
      .has_time = (flags & static_cast<std::uint8_t>(Flag::has_time)) != 0,
      .expanded = true,
  };
  const auto row = HistoryRowGeometry::derive(bounds, chrome, metrics.row_height, measured);
  const auto layout = HistoryCard::measure(row, chrome, metrics, text);
  probe::write(layout.intrinsic_height);
  probe::write(layout.height);
  probe::write(layout.text_y);
  probe::writeRect(layout.meta);
  probe::write(layout.line_limit);
  probe::write(layout.shown);
  probe::write(layout.more);
  for (std::uint16_t index = 0; index < layout.shown; ++index) {
    probe::writeText(layout.lines[index]);
  }
}

void commandLines(SystemAllocator &memory) {
  const auto bounds = probe::readRect();
  const auto cell_width = static_cast<float>(probe::read<std::uint32_t>());
  const auto query = probe::readText(memory);
  const auto count = probe::read<std::uint16_t>();
  HistoryMatchHighlight highlight{query};
  for (std::uint16_t index = 0; index < count; ++index) {
    const auto continues = probe::read<std::uint8_t>() != 0;
    const auto text = probe::readText(memory);
    auto area = bounds;
    area.y += static_cast<float>(index) * bounds.height;
    const auto layout = HistoryCommandLine::derive(area, {.needed = textWidth(text, cell_width), .cell_width = cell_width, .continues = continues});
    auto record = [](Rect match, std::string_view cluster) {
      probe::write(std::uint8_t{1});
      probe::writeRect(match);
      probe::writeText(cluster);
    };
    highlight.paint(text, layout.text, cell_width, record);
    probe::write(std::uint8_t{0});
    probe::writeRect(layout.text);
    probe::writeRect(layout.marker);
    probe::writeText(layout.mark);
  }

  probe::write(static_cast<std::uint16_t>(highlight.matched()));
}

}

int main() try {
  SystemAllocator memory;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    switch (static_cast<Operation>(operation)) {
    case Operation::wrap:
      wrappedLines(memory);
      break;
    case Operation::card:
      card(memory);
      break;
    case Operation::command_line:
      commandLines(memory);
      break;
    default:
      return 1;
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
