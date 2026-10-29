#pragma once

#include "../agents/builtin_manifests.hpp"
#include "../agents/description.hpp"
#include "../graphics/limits.hpp"
#include "../persistence/options.hpp"
#include "../terminal/control/policy.hpp"

namespace telar::runtime {

struct RuntimeOptions {
  std::string_view socket;
  std::string_view executable;
  checkpoint::Options session;
  bool fresh = false;
  bool capture_output = false;
  const AgentManifests *manifests = &builtin_manifests;
  DescriptionOptions descriptions;
  checkpoint::CloneOptions clone{};
  GraphicsLimits graphics;
  control::Policy control_policy{};
};

}
