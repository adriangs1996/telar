#pragma once

#include <cstdint>

namespace telar::gui {

struct PaneBottomReservation {
  static constexpr std::uint16_t shelf_rows = 6;
  static constexpr std::uint16_t shelf_minimum_rows = 3;
  static constexpr std::uint16_t pane_minimum_rows = 3;

  std::uint64_t pane_id = 0;
  std::uint16_t preferred_height = shelf_rows;
  std::uint16_t minimum_height = shelf_minimum_rows;
  std::uint16_t minimum_pane_height = pane_minimum_rows;

  bool operator==(const PaneBottomReservation &) const = default;
};

}
