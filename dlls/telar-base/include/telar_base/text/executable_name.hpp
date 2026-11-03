#pragma once

#include "telar_base/text/ascii.hpp"
#include <string_view>

namespace telar::runtime {

inline constexpr std::string_view withoutExecutableSuffix(std::string_view name) noexcept {
  for (const auto suffix : {std::string_view{".exe"}, std::string_view{".cmd"}, std::string_view{".bat"}, std::string_view{".js"}}) {
    if (name.size() >= suffix.size() && asciiEqualIgnoreCase(name.substr(name.size() - suffix.size()), suffix)) {
      return name.substr(0, name.size() - suffix.size());
    }
  }

  return name;
}

}
