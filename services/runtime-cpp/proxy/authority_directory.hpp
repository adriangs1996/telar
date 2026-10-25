#pragma once

#include "../memory/allocator.hpp"
#include "../platform/process_environment.hpp"
#include <stdexcept>

namespace telar::runtime {

template <Allocator Memory, EnvironmentLookup Environment>
String<Memory> proxyAuthorityDirectory(Memory &memory, const Environment &environment) {
  String<Memory> path{environment.lookup("XDG_DATA_HOME"), AllocatorRef<char, Memory>{memory}};
  if (path.empty() || path.front() != '/') {
    path = environment.lookup("HOME");
    if (path.empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy"};
    }

    path += "/.local/share";
  }

  path += "/telar/proxy";
  return path;
}

}
