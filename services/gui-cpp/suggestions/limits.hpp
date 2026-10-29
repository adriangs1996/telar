#pragma once

#include <cstddef>

namespace telar::gui {

struct SuggestionLimits {
  static constexpr std::size_t request_bytes = 512;
  static constexpr std::size_t text_bytes = 1024;
};

}
