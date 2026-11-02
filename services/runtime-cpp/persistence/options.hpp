#pragma once

#include <string_view>

namespace telar::runtime::checkpoint {

struct Options {
  std::string_view path;
  bool resume_agents = true;
};

}
