#pragma once

#include "../graphics/media_budget.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"

namespace telar::runtime {

struct PaneLaunch {
  TerminalSize size;
  MediaBudget &media_budget;
  GraphicsLimits graphics;
};

}
