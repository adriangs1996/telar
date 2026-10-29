#pragma once

#include "../proxy/client_configuration.hpp"
#include "../terminal/control/policy.hpp"

namespace telar::runtime {

struct PaneLaunchOptions {
  std::string_view socket;
  ProxyClientConfiguration proxy{};
  control::Policy control_policy{};
};

}
