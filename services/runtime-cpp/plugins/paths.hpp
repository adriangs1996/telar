#pragma once

#include "../platform/process_environment.hpp"
#include "../text/hexadecimal.hpp"
#include "package.hpp"

namespace telar::runtime::plugins {

class Paths {
public:
  template <Allocator Memory, EnvironmentLookup Environment>
  static String<Memory> trust(Memory &memory, const Environment &environment) {
    auto path = base(memory, environment, "XDG_CONFIG_HOME", "/.config");
    path += "/telar/trust.json";
    return path;
  }

  template <Allocator Memory, EnvironmentLookup Environment>
  static String<Memory> installation(Memory &memory, const Environment &environment, const Package &package) {
    auto path = base(memory, environment, "XDG_DATA_HOME", "/.local/share");
    path += "/telar/plugins/";
    path += package.manifest.id.view();
    path += '/';
    appendLowerHex(path, package.digest);
    return path;
  }

private:
  template <Allocator Memory, EnvironmentLookup Environment>
  static String<Memory> base(Memory &memory, const Environment &environment, const char *variable, std::string_view fallback) {
    String<Memory> path{environment.lookup(variable), AllocatorRef<char, Memory>{memory}};
    if (path.empty()) {
      path = environment.lookup("HOME");
      if (path.empty()) {
        throw std::invalid_argument{"Home directory unavailable for plugins"};
      }
      path += fallback;
    }
    return path;
  }
};

}
