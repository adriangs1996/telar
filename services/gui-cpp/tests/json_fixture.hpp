#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <stdexcept>
#include <string>

#pragma once


import telar.base.text;

namespace telar::gui::test {

inline runtime::JsonValue requiredJsonField(const runtime::JsonValue &object, std::string_view name) {
  const auto value = object.field(name);
  if (!value) {
    throw std::runtime_error{"Missing JSON field: " + std::string{name}};
  }

  return *value;
}

}
