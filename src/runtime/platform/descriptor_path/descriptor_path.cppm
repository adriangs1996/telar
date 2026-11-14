module;
#include "telar_platform/descriptor_path.hpp"
#include <limits.h>

export module telar.runtime.platform.descriptor_path;

import std;

export import telar.platform.error;

// Interface: platform/descriptor_path.cppm
export {
  namespace telar::runtime {

    inline std::array<char, PATH_MAX> descriptorPath(int descriptor) {
      std::array<char, PATH_MAX> path{};
      if (!descriptorPath(descriptor, path)) {
        throw SystemError{"Resolve open file path"};
      }

      return path;
    }

  }
}
