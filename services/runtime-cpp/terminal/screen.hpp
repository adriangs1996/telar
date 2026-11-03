#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "text_metadata.hpp"
#include <cstring>

namespace telar::runtime {

struct ScreenCell {
  std::array<Byte, 16> text{' '};
  Byte length = 1;
  CellWidth width = CellWidth::single;
  CellStyle style{};

  bool operator==(const ScreenCell &other) const noexcept {
    return std::memcmp(this, &other, sizeof(ScreenCell)) == 0;
  }

  Cell view() const noexcept {
    return Cell{width, style, std::span<const Byte>{text}.first(length)};
  }
};

static_assert(sizeof(ScreenCell) == 32);
static_assert(std::has_unique_object_representations_v<ScreenCell>);

template <Allocator Memory>
class Screen {
public:
  explicit Screen(Memory &memory)
      : cells(AllocatorRef<ScreenCell, Memory>{memory}),
        row_revisions(AllocatorRef<std::uint64_t, Memory>{memory}),
        row_flags(AllocatorRef<Byte, Memory>{memory}),
        metadata(memory) {}

  void reserve(std::uint16_t columns, std::uint16_t lines) {
    constexpr std::size_t maximum_cells = 130359;
    const auto count = static_cast<std::size_t>(columns) * lines;
    if (columns == 0 || lines == 0 || count > maximum_cells) {
      throw EncodingError{"Terminal size exceeds the wire limit"};
    }

    cells.reserve(count);
    row_revisions.reserve(lines);
    row_flags.reserve(lines);
  }

  void resize(std::uint16_t columns, std::uint16_t lines) {
    reserve(columns, lines);
    cells.resize(static_cast<std::size_t>(columns) * lines);
    row_revisions.resize(lines);
    row_flags.resize(lines);
    cols = columns;
    rows = lines;
    ++revision;
    ++metadata_revision;
    std::fill(row_revisions.begin(), row_revisions.end(), revision);
  }

  Vector<ScreenCell, Memory> cells;
  Vector<std::uint64_t, Memory> row_revisions;
  Vector<Byte, Memory> row_flags;
  TextMetadataCapture<Memory> metadata;
  std::uint64_t metadata_revision = 1;
  std::uint16_t cols = 0;
  std::uint16_t rows = 0;
  std::uint64_t revision = 0;
  Cursor cursor{};
  Mouse mouse{};
  InputModes input_modes{};
  PointerShape pointer_shape{};
  Scroll scroll{};
};

}
