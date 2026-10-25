#pragma once

#include <string_view>

namespace telar::runtime::checkpoint {

struct Options {
  std::string_view path;
  bool resume_agents = true;
};

struct CloneOptions {
  std::string_view source_checkpoint{};
  std::string_view source_socket{};
  std::string_view shell = "/bin/sh";
};

}
