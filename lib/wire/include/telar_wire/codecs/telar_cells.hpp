#pragma once

#include "../serializers/telar_cells.hpp"
#include "tbc/view.hpp"
#include "telar_base/ds/values.hpp"

namespace telar {

  // Styles are inherited only within one span. Text borrows the encoded frame.
  class CellReader {
  public:
    CellReader(std::span<const Byte> bytes, std::uint32_t count);

    ds::Option<Cell> next();

  private:
    std::span<const Byte> input{};
    std::uint32_t remaining = 0;
    ds::Option<CellStyle> previous_style{};
  };

  struct CellRunCodec {
    static std::size_t encodedSize(std::span<const Cell> cells);

    // The encoded bytes are the front of the buffer, region `a`.
    static tbc::view<std::span<Byte>, tbc::lt::a> encode(std::span<const Cell> cells, tbc::view<std::span<Byte>, tbc::lt::a> buffer);
  };

} // namespace telar
