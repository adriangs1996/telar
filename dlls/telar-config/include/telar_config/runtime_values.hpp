#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_config/agents/builtin_manifests.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_config/history/filters.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_config/proxy/options.hpp"
#include "telar_config/terminal/control/policy.hpp"
#include "telar_plugins/specifications.hpp"
#include <chrono>
#include <limits.h>

namespace telar::runtime::config {

template <Allocator Memory>
struct CommandValues {
  explicit CommandValues(Memory &memory)
      : arguments(AllocatorRef<String<Memory>, Memory>{memory}) {}

  Vector<String<Memory>, Memory> arguments;
  std::chrono::milliseconds timeout{15'000};
  std::chrono::milliseconds idle_timeout{300'000};
};

template <Allocator Memory>
struct RuntimeValues {
  explicit RuntimeValues(Memory &memory)
      : history_path(AllocatorRef<char, Memory>{memory}),
        session_path(AllocatorRef<char, Memory>{memory}),
        engine(memory),
        descriptions(memory),
        proxy(memory) {}

  String<Memory> history_path;
  String<Memory> session_path;
  HistoryFilters history_filters;
  CommandValues<Memory> engine;
  CommandValues<Memory> descriptions;
  ProxyOptions<Memory> proxy;
  plugins::Specifications plugins;
  FixedText<PATH_MAX> configuration_directory;
  AgentManifests manifests = builtin_manifests;
  LimitNotices limits;
  GraphicsLimits graphics;
  control::Policy control_policy{};
  bool capture_output = false;
  bool persist_session = true;
  bool resume_agents = true;
};

template <Allocator Memory>
RuntimeValues(Memory &memory) -> RuntimeValues<Memory>;

}
