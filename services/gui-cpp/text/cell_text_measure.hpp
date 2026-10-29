#pragma once

#include "grapheme_cursor.hpp"
#include <cstdint>
#include <string_view>

namespace telar::gui {

inline std::uint32_t cellTextColumns(std::string_view text) {
  GraphemeCursor cursor{text};
  std::uint32_t columns = 0;
  while (cursor.next()) {
    columns += cursor.columns();
  }

  return columns;
}

}
