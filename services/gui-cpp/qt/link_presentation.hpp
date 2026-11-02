#pragma once

#include "core/terminal_surface.hpp"

#include "core/geometry.hpp"
#include "links/link_hit.hpp"
#include <memory>
#include <optional>

namespace telar::gui::qt {

struct PresentedLink {
  TerminalSurface surface;
  std::shared_ptr<const LinkHit> link;
  std::optional<Rect> cover;
};

}
