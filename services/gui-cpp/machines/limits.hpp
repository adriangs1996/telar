#pragma once

#include <cstddef>

namespace telar::gui {

struct MachineLimits {
  static constexpr std::size_t profiles = 16;
  static constexpr std::size_t window_slots = profiles + 1;
  static constexpr std::size_t label_bytes = 32;
  static constexpr std::size_t destination_bytes = 255;
  static constexpr std::size_t color_bytes = 24;
  static constexpr std::size_t program_bytes = 255;
  static constexpr std::size_t file_bytes = std::size_t{32} * 1024;
  static constexpr std::size_t failure_bytes = 256;
};

}
