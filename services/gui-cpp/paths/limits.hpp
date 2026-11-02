#pragma once

#include <cstddef>

namespace telar::gui {

struct PathPickerLimits {
  static constexpr std::size_t root_bytes = 4096;
  static constexpr std::size_t query_bytes = 64;
  static constexpr std::size_t path_bytes = 1024;
  static constexpr std::size_t results = 50;
  static constexpr std::size_t tracked_requests = 32;
  static constexpr std::size_t error_bytes = 128;
  static constexpr std::size_t page_bytes = results * path_bytes;
  static constexpr std::size_t absolute_bytes = root_bytes + path_bytes + 1;
  static constexpr std::size_t quote_escape_bytes = 4;
  static constexpr std::size_t quoted_bytes = quote_escape_bytes * (root_bytes + path_bytes);
};

}
