export module telar.gui.foundation.system:path_limits;

import std;
import telar.sys.posix;

export {
  namespace telar::gui::inline foundation::inline system {

    struct PathLimits {
      static constexpr std::size_t path_bytes = PATH_MAX;
      static constexpr std::size_t component_bytes = NAME_MAX;
    };

  }
}
