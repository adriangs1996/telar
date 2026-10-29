#pragma once

#include "link_presentation.hpp"
#include "presentation/frame_pacer.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

struct TerminalPreparation {
  FramePacer::Pane pane;
  std::optional<PresentedLink> links;
  std::uint64_t revision = 0;
};

}
