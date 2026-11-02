#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <limits>
#include <string_view>

namespace telar::gui {

class CopyRangeParser {
public:
  static CopySelection parse(std::uint64_t pane_id, std::string_view text) {
    if (pane_id == 0) {
      throw EncodingError{"Invalid copy pane identity"};
    }

    CopySelection selection;
    selection.pane_id = pane_id;
    selection.start_x = takeCoordinate<std::uint16_t>(text, ',');
    selection.start_y = takeCoordinate<std::uint32_t>(text, ':');
    selection.end_x = takeCoordinate<std::uint16_t>(text, ',');
    selection.end_y = coordinate<std::uint32_t>(text);

    return selection;
  }

private:
  template <std::unsigned_integral Coordinate>
  static Coordinate takeCoordinate(std::string_view &text, char separator) {
    const auto boundary = text.find(separator);
    if (boundary == std::string_view::npos) {
      throw EncodingError{"Invalid copy range separators"};
    }

    const auto result = coordinate<Coordinate>(text.substr(0, boundary));
    text.remove_prefix(boundary + 1);

    return result;
  }

  template <std::unsigned_integral Coordinate>
  static Coordinate coordinate(std::string_view text) {
    if (text.empty() || text.front() == '_' || text.back() == '_') {
      throw EncodingError{"Invalid copy range coordinate"};
    }

    constexpr std::uint64_t decimal_base = 10;
    constexpr std::uint64_t maximum = std::numeric_limits<Coordinate>::max();
    std::uint64_t result = 0;

    for (const char character : text) {
      if (character == '_') {
        continue;
      }

      if (character < '0' || character > '9') {
        throw EncodingError{"Invalid copy range digit"};
      }

      const auto digit = static_cast<std::uint64_t>(character - '0');
      if (result > (maximum - digit) / decimal_base) {
        throw EncodingError{"Copy range coordinate exceeds capacity"};
      }

      result = (result * decimal_base) + digit;
    }

    return static_cast<Coordinate>(result);
  }
};

}
