#pragma once

#include "text/json.hpp"
#include <stdexcept>
#include <string>
#include <string_view>

namespace telar::gui::test {

inline runtime::JsonValue requiredJsonField(const runtime::JsonValue &object, std::string_view name) {
  const auto value = object.field(name);
  if (!value) {
    throw std::runtime_error{"Missing JSON field: " + std::string{name}};
  }

  return *value;
}

}
