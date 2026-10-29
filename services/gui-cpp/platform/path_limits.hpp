#pragma once

#include <cstddef>
#include <sys/param.h>

namespace telar::gui::platform {

struct PathLimits {
  static constexpr std::size_t path_bytes = PATH_MAX;
  static constexpr std::size_t component_bytes = NAME_MAX;
};

}
