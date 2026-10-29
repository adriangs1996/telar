#include "core/memory.hpp"
#include "fonts/font_role.hpp"
#include "fonts/ligature_coverage.hpp"
#include "fonts/row_text_layout.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "terminal/screen.hpp"
#include "terminal/text_runs.hpp"
#include "tests/font_fixture.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <filesystem>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::fonts;

struct CellInput {
  std::uint32_t flags = 0;
  std::uint32_t foreground = 0;
  std::uint32_t background = 0;
  std::uint32_t underline_color = 0;
  std::uint32_t width = 0;
};

struct RowInput {
  std::uint32_t pixel_height = 0;
  std::uint32_t cell_width = 0;
  std::uint32_t cursor = 0;
  std::uint32_t selection_anchor = 0;
  std::uint32_t selection_head = 0;
};

struct GlyphOutput {
  std::int32_t index = 0;
  std::int32_t x_advance = 0;
  std::int32_t y_advance = 0;
  std::int32_t x_offset = 0;
  std::int32_t y_offset = 0;
  std::int32_t cell_offset = 0;
};

std::optional<std::uint32_t> nextSize() {
  std::uint32_t size = 0;
  const auto read = std::fread(&size, sizeof(size), 1, stdin);
  if (read == 0 && std::feof(stdin) != 0) {
    return std::nullopt;
  }

  if (read != 1 || size > std::numeric_limits<std::uint16_t>::max()) {
    throw std::runtime_error{"InvalidRowProbeSize"};
  }

  return size;
}

CellColor readColor(std::uint32_t value) {
  constexpr unsigned byte_bits = 8;
  constexpr unsigned kind_shift = 3 * byte_bits;
  constexpr unsigned byte_mask = 255;
  const auto kind = static_cast<CellColor::Kind>(value >> kind_shift);
  if (kind == CellColor::Kind::default_color) {
    return {};
  }

  if (kind == CellColor::Kind::indexed) {
    return {.kind = kind, .channels = {static_cast<Byte>(value), 0, 0}};
  }

  return {.kind = kind, .channels = {static_cast<Byte>((value >> (2 * byte_bits)) & byte_mask), static_cast<Byte>((value >> byte_bits) & byte_mask), static_cast<Byte>(value & byte_mask)}};
}

CellValue readCell(SystemAllocator &memory) {
  const auto input = probe::read<CellInput>();
  const auto text = probe::readText(memory);
  CellValue cell;
  cell.style = {.flags = static_cast<std::uint16_t>(input.flags), .foreground = readColor(input.foreground), .background = readColor(input.background), .underline_color = readColor(input.underline_color)};
  cell.width = static_cast<CellWidth>(input.width);
  if (text.size() > cell.text.size()) {
    throw std::length_error{"RowProbeCellTooLong"};
  }

  cell.length = static_cast<Byte>(text.size());
  for (std::size_t index = 0; index < text.size(); ++index) {
    cell.text[index] = static_cast<Byte>(text[index]);
  }

  return cell;
}

void writeGlyphs(const RowTextLayout<SystemAllocator> &layout, std::size_t column) {
  const auto range = layout.cell(column);
  std::uint32_t count = 0;
  for (const auto &span : layout.spans().subspan(range.first_span, range.span_count)) {
    if (span.role == FontRole::primary) {
      count += static_cast<std::uint32_t>(span.count);
    }
  }

  probe::write(count);
  for (const auto &span : layout.spans().subspan(range.first_span, range.span_count)) {
    if (span.role != FontRole::primary) {
      continue;
    }

    for (const auto &glyph : layout.glyphs().subspan(span.first, span.count)) {
      probe::write(GlyphOutput{.index = static_cast<std::int32_t>(glyph.index), .x_advance = glyph.x_advance, .y_advance = glyph.y_advance, .x_offset = glyph.x_offset, .y_offset = glyph.y_offset, .cell_offset = span.offset});
    }
  }
}

void rowCase(test::FontFixture<SystemAllocator> &fonts, SystemAllocator &memory, std::uint32_t count) {
  const auto input = probe::read<RowInput>();
  constexpr auto absent = std::numeric_limits<std::uint32_t>::max();
  const RowTextRequest request{.pixel_height = static_cast<std::uint16_t>(input.pixel_height), .cell_width = static_cast<std::uint16_t>(input.cell_width), .cursor = input.cursor == absent ? std::nullopt : std::optional<std::size_t>{input.cursor}, .selection = {.anchor = input.selection_anchor == absent ? -1 : static_cast<int>(input.selection_anchor), .head = input.selection_head == absent ? -1 : static_cast<int>(input.selection_head)}};
  Vector<CellValue, SystemAllocator> cells{AllocatorRef<CellValue, SystemAllocator>{memory}};
  cells.reserve(count);
  for (std::size_t index = 0; index < count; ++index) {
    cells.push_back(readCell(memory));
  }

  const auto &coverage = fonts.face(FontRole::primary).ligatures();
  probe::write(std::array<std::uint32_t, 2>{coverage.reach(), static_cast<std::uint32_t>(coverage.joins())});
  TextRuns<SystemAllocator> runs{memory};
  runs.reserve(count);
  for (std::size_t column = 0; column < cells.size(); ++column) {
    auto cell = cells[column];
    probe::write(static_cast<std::uint32_t>(coverage.role(cell.utf8())));
    if (request.selection.contains(column)) {
      cell.style.flags ^= static_cast<std::uint16_t>(CellAttribute::inverse);
    }

    runs.append(coverage, cell, request.cursor == column);
  }

  runs.close(coverage.reach());
  for (std::size_t column = 0; column < cells.size();) {
    const auto run = runs.at(column);
    probe::write(std::array<std::uint32_t, 2>{static_cast<std::uint32_t>(run.count), static_cast<std::uint32_t>(run.together)});
    column += run.count;
  }

  probe::write(std::uint32_t{0});
  RowTextLayout<SystemAllocator> layout{memory};
  layout.shape(fonts, cells, request);
  for (std::size_t column = 0; column < cells.size(); ++column) {
    writeGlyphs(layout, column);
  }
}

}

int main(int argc, char **argv) {
  const auto arguments = std::span{argv, static_cast<std::size_t>(argc)};
  constexpr std::size_t expected_arguments = 3;
  if (arguments.size() != expected_arguments) {
    return 1;
  }

  try {
    SystemAllocator memory;
    test::FontFixture fonts{memory, std::filesystem::path{arguments[1]}, arguments[2]};
    while (const auto count = nextSize()) {
      rowCase(fonts, memory, *count);
    }
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));
    return 1;
  }
}
