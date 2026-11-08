module;
#include <cstdint>

export module telar.gui.tests.json_fixture;

import std;
export import telar.base.memory;
export import telar.base.text;

export {
namespace telar::gui::test {

inline runtime::JsonValue requiredJsonField(const runtime::JsonValue &object, std::string_view name) {
  const auto value = object.field(name);
  if (!value) {
    throw std::runtime_error{"Missing JSON field: " + std::string{name}};
  }

  return *value;
}

}
}
