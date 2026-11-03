#pragma once

#include "../agents/description.hpp"
#include "../persistence/options.hpp"
#include "telar_config/agents/builtin_manifests.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_config/terminal/control/policy.hpp"

namespace telar::runtime {

struct RuntimeOptions {
  std::string_view socket;
  std::string_view cli_executable;
  checkpoint::Options session;
  bool fresh = false;
  bool capture_output = false;
  const AgentManifests *manifests = &builtin_manifests;
  DescriptionOptions descriptions;
  GraphicsLimits graphics;
  control::Policy control_policy{};
};

}
