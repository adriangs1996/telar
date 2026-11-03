#pragma once

#include <concepts>
#include <cstdlib>
#include <string_view>

namespace telar::runtime {

struct ProcessEnvironment {
  std::string_view lookup(const char *name) const noexcept {
    const auto *value = std::getenv(name);
    return value == nullptr ? std::string_view{} : std::string_view{value};
  }
};

template <typename Environment>
concept EnvironmentLookup = requires(const Environment &environment, const char *name) {
  { environment.lookup(name) } -> std::same_as<std::string_view>;
};

}
