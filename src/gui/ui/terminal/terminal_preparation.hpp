#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/links/link_presentation.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <variant>

#pragma once

import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

  struct TerminalPreparation {
    FramePacer::Pane pane;
    std::optional<PresentedLink> links;
    std::uint64_t revision = 0;
  };

}
