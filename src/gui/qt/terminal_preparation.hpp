#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "link_presentation.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>

#pragma once



import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

struct TerminalPreparation {
  FramePacer::Pane pane;
  std::optional<PresentedLink> links;
  std::uint64_t revision = 0;
};

}
