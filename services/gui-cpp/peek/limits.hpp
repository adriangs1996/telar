#pragma once

#include "suggestions/limits.hpp"
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct PeekLimits {
  static constexpr std::uint16_t rows = 16;
  static constexpr std::size_t row_cells = 256;
  static constexpr std::size_t cell_bytes = 4;
  static constexpr std::size_t text_bytes = rows * row_cells * cell_bytes;
  static constexpr std::size_t message_bytes = SuggestionLimits::request_bytes;
};

}
