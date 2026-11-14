module;
#include <limits.h>

export module telar.runtime.platform.descriptor_path;

import std;

// Interface: platform/descriptor_path.cppm
export {
  namespace telar::runtime {

    std::array<char, PATH_MAX> descriptorPath(int descriptor);

  }
}
