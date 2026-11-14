module;
#include <limits.h>
#include <sys/param.h>

export module telar.gui.platform.path_limits;

import std;

export {
  namespace telar::gui::platform {

    struct PathLimits {
      static constexpr std::size_t path_bytes = PATH_MAX;
      static constexpr std::size_t component_bytes = NAME_MAX;
    };

  }
}
