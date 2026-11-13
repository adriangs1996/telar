#pragma once

#include <optional>
#include <stdexcept>
#include <utility>

namespace telar::gui::test {

inline void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <typename Value>
Value requireValue(std::optional<Value> value, const char *message) {
  if (!value) {
    throw std::runtime_error{message};
  }

  return std::move(*value);
}

}
