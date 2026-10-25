#pragma once

#include "../proxy/client_configuration.hpp"

namespace telar::runtime {

struct PaneLaunchOptions {
  std::string_view socket;
  ProxyClientConfiguration proxy{};
};

}
