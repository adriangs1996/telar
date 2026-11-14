module;
#include "telar_platform/descriptor_path.hpp"
#include <limits.h>

module telar.runtime.platform.descriptor_path;

import telar.platform.error;

namespace telar::runtime {

  std::array<char, PATH_MAX> descriptorPath(int descriptor) {
    std::array<char, PATH_MAX> path{};
    if (!descriptorPath(descriptor, path)) {
      throw SystemError{"Resolve open file path"};
    }

    return path;
  }

}
