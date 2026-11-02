#pragma once

#include "record.hpp"
#include <concepts>

namespace telar::runtime::proxy_trust {

inline constexpr std::string_view linux_certificate_path = "/usr/local/share/ca-certificates/telar-proxy.crt";

struct Destination {
  Destination(std::string_view path) : Destination(Backend::macos, path) {}

  template <typename Text>
    requires std::convertible_to<const Text &, std::string_view>
  Destination(const Text &path) : Destination(std::string_view{path}) {}

  Destination(Backend selected, std::string_view path) : backend(selected) {
    store.assign(path);
  }

  Backend backend;
  FixedText<PATH_MAX> store;
};

}
