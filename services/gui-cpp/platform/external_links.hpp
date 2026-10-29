#pragma once

#include <string_view>

namespace telar::gui::platform {

struct AppleExternalLinks {
  static constexpr std::string_view executable = "/usr/bin/open";
};

struct LinuxExternalLinks {
  static constexpr std::string_view executable = "xdg-open";
};

#ifdef __APPLE__
using NativeExternalLinks = AppleExternalLinks;
#else
using NativeExternalLinks = LinuxExternalLinks;
#endif

}
