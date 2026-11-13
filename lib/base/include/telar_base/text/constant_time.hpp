#pragma once

#include <cstddef>
#include <string_view>

namespace telar::runtime {

  // Whether two secrets of public length are equal, in time that depends on the length alone, so
  // how long a forged candidate takes to fail reveals nothing of the secret.
  inline bool constantTimeEqual(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    unsigned difference = 0;

    for (std::size_t index = 0; index < left.size(); ++index) {
      difference |= static_cast<unsigned char>(left[index]) ^ static_cast<unsigned char>(right[index]);
    }

    return difference == 0;
  }

}
