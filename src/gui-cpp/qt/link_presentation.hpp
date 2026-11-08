#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <limits>
#include <optional>
#include <array>
#include "../terminal/cell_position.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <memory>

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
