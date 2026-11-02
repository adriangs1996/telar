#pragma once

#include "core/geometry.hpp"
#include "link_match.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>

namespace telar::gui {

struct LinkHit {
  std::uint64_t pane_id = 0;
  std::uint64_t generation = 0;
  TabLocation location;
  Rect content;
  std::uint32_t scroll_offset = 0;
  Rect area;
  LinkMatch match;

  [[nodiscard]] bool operator==(const LinkHit &other) const noexcept {
    return pane_id == other.pane_id && generation == other.generation && sameTab(location, other.location) && content == other.content && scroll_offset == other.scroll_offset && area == other.area && match == other.match;
  }
};

}
