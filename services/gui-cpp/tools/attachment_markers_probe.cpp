#include "attachments/marker_removal.hpp"
#include "attachments/marker_screen.hpp"
#include "attachments/numeric_markers.hpp"
#include "attachments/path_markers.hpp"
#include "core/memory.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

using namespace telar;
using namespace telar::gui;
constexpr std::uint64_t maximum_columns = 4096;
constexpr std::uint64_t maximum_rows = 16;
constexpr std::size_t path_capacity = 8;
constexpr int record_tag = 1;

std::uint64_t read() {
  std::uint64_t value = 0;
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    const auto byte = std::cin.get();
    if (byte == std::char_traits<char>::eof()) {
      throw std::runtime_error{"TruncatedInput"};
    }

    value |= static_cast<std::uint64_t>(byte) << (index * std::numeric_limits<unsigned char>::digits);
  }

  return value;
}

void write(std::uint64_t value) {
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    std::cout.put(static_cast<char>((value >> (index * std::numeric_limits<unsigned char>::digits)) & std::numeric_limits<unsigned char>::max()));
  }
}

void writeFlag(bool value) {
  write(value ? 1U : 0U);
}

void point(CellPosition value) {
  write(value.x);
  write(value.y);
}

void numeric(const std::optional<NumericAttachmentMarker> &value) {
  writeFlag(value.has_value());
  if (value) {
    write(value->number);
    point(value->start);
    point(value->end);
  }
}

void plan(const AttachmentMarkerPlan &value) {
  if (value.limit) {
    write(1);
    write(static_cast<std::uint64_t>(*value.limit));
    write(value.requested ? static_cast<std::uint64_t>(*value.requested) : std::numeric_limits<std::uint64_t>::max());
  } else if (value.removal) {
    write(2);
    write(static_cast<std::uint64_t>(value.removal->direction));
    write(value.removal->steps);
    write(static_cast<std::uint64_t>(value.removal->deletion));
    write(value.removal->deletions);
    write(value.removal->keyCount());
  } else {
    write(0);
  }
}

void boundaries(AttachmentMarkerScreen screen, std::uint16_t number) {
  NumericAttachmentMarkers scan{screen};
  const CellPosition cursor{.x = screen.cursor.x, .y = screen.cursor.y};
  bool backward = false;
  bool forward = false;
  while (const auto marker = scan.next()) {
    if (marker->number == number) {
      backward = backward || marker->end == cursor;
      forward = forward || marker->start == cursor;
    }
  }

  writeFlag(backward);
  writeFlag(forward);
}

void observe(AttachmentMarkerScreen screen, std::uint16_t number) {
  NumericAttachmentMarkers scan{screen};
  while (const auto marker = scan.next()) {
    numeric(marker);
  }

  numeric(std::nullopt);
  numeric(NumericAttachmentMarkers::closest(screen, number));
  writeFlag(NumericAttachmentMarkers::present(screen, number));
  boundaries(screen, number);
  writeFlag(screen.promptContinues());
  const auto steps = NumericAttachmentMarkers::steps(screen, screen.cursor.y, 0, screen.cursor.x);
  write(steps ? static_cast<std::uint64_t>(*steps) : std::numeric_limits<std::uint64_t>::max());
  plan(AttachmentMarkerPlanning::placeholder(screen, number != 0 ? number : 1));
  std::array<PathAttachmentMarker, path_capacity> paths{};
  const auto count = PathAttachmentMarkers::collect(screen, paths);
  write(count);
  for (std::size_t index = 0; index < count; ++index) {
    const auto marker = paths[index];
    for (const auto byte : marker.uuid) {
      write(byte);
    }

    point(marker.start);
    point(marker.end);
    write(marker.cells ? static_cast<std::uint64_t>(*marker.cells) : std::numeric_limits<std::uint64_t>::max());
    writeFlag(PathAttachmentMarkers::cursorAt(screen, marker.start));
    writeFlag(PathAttachmentMarkers::cursorAt(screen, marker.end));
    const auto cursor = PathAttachmentMarkers::cursorOnRow(screen, static_cast<std::uint16_t>(marker.end.y));
    write(cursor ? static_cast<std::uint64_t>(*cursor) : std::numeric_limits<std::uint64_t>::max());
  }

  plan(count != 0 ? AttachmentMarkerPlanning::path(screen, paths.front().uuid) : AttachmentMarkerPlan{});
}

void consume(SystemAllocator &memory) {
  const auto columns = read();
  const auto rows = read();
  if (columns == 0 || rows == 0 || columns > maximum_columns || rows > maximum_rows) {
    throw std::invalid_argument{"InvalidProbeGrid"};
  }

  const auto cursor_x = read();
  const auto cursor_y = read();
  const auto visible = read();
  const auto number = read();
  if (cursor_x > columns || cursor_y >= rows || number > std::numeric_limits<std::uint16_t>::max()) {
    throw std::invalid_argument{"InvalidProbeCursor"};
  }

  Vector<CellValue, SystemAllocator> cells{AllocatorRef<CellValue, SystemAllocator>{memory}};
  cells.resize(static_cast<std::size_t>(columns * rows));
  for (auto &cell : cells) {
    const auto length = read();
    const auto width = read();
    const auto flags = read();
    if (length > CellValue::text_capacity || width > static_cast<std::uint8_t>(CellWidth::wide)) {
      throw std::invalid_argument{"InvalidProbeCell"};
    }

    cell.length = static_cast<std::uint8_t>(length);
    cell.width = static_cast<CellWidth>(width);
    cell.style.flags = static_cast<std::uint16_t>(flags);
    for (std::size_t index = 0; index < length; ++index) {
      cell.text[index] = static_cast<std::uint8_t>(read());
    }
  }

  observe({.cells = cells, .columns = static_cast<std::uint16_t>(columns), .rows = static_cast<std::uint16_t>(rows), .cursor = {.visible = visible != 0, .x = static_cast<std::uint16_t>(cursor_x), .y = static_cast<std::uint16_t>(cursor_y)}}, static_cast<std::uint16_t>(number));
}

}

int main() try {
  SystemAllocator memory;
  for (;;) {
    const auto tag = std::cin.get();
    if (tag == std::char_traits<char>::eof()) {
      return std::cout.good() ? 0 : 1;
    }

    if (tag != record_tag) {
      throw std::invalid_argument{"InvalidProbeRecord"};
    }

    consume(memory);
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
