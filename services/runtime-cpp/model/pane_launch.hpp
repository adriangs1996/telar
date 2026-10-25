#pragma once

#include "../graphics/limits.hpp"
#include "../graphics/media_budget.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

struct PaneLaunch {
  TerminalSize size;
  MediaBudget &media_budget;
  GraphicsLimits graphics;
};

}
