#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <optional>
#include <stdexcept>
#include <utility>

#pragma once

import telar.base.ds;

namespace telar::gui::test {

  inline void require(bool condition, const char* message) {
    if (!condition) {
      throw std::runtime_error{message};
    }
  }

  template <typename Value>
  Value requireValue(ds::Option<Value> value, const char* message) {
    if (!value) {
      throw std::runtime_error{message};
    }

    return std::move(value.getMut());
  }

}
