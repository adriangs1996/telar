#pragma once

#include "callback.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_plugins/package.hpp"
#include "telar_plugins/package_limits.hpp"
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct PluginInvocation {
  runtime::plugins::Package package;
  runtime::FixedText<runtime::plugins::PackageLimits::action_bytes> action;
  BindingContext context;
  std::uint64_t configuration_generation = 0;
  std::size_t package_index = 0;
};

}
