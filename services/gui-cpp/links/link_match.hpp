#pragma once

#include "link_target.hpp"
#include "terminal/cell_position.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

struct LinkMatch {
  LinkTarget target;
  CellPosition start;
  CellPosition end;
  std::optional<std::uint16_t> metadata_index = std::nullopt;

  bool operator==(const LinkMatch &) const = default;
};

}
