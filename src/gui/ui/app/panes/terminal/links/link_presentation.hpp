#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "terminal/cell_position.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.core.metrics;
import telar.gui.links.link_hover;

namespace telar::gui::qt {

  struct PresentedLink {
    TerminalSurface surface;
    std::shared_ptr<const LinkHit> link;
    std::optional<Rect> cover;
  };

}
