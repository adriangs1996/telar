#pragma once

#include "../agents/builtin_manifests.hpp"
#include "../graphics/limits.hpp"
#include "../history/filters.hpp"
#include "../memory/allocator.hpp"
#include "../plugins/specifications.hpp"
#include "../proxy/options.hpp"
#include "limit_notices.hpp"
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
  bool capture_output = false;
  bool persist_session = true;
  bool resume_agents = true;
};

template <Allocator Memory>
RuntimeValues(Memory &memory) -> RuntimeValues<Memory>;

}
