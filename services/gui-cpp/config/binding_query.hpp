#pragma once

#include "action_descriptions.hpp"
#include "action_query.hpp"
#include "config/command_tab_registry.hpp"
#include "core/json_writer.hpp"
#include "core/memory.hpp"
#include "input/configuration.hpp"
#include "input_query.hpp"
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class BindingQuery {
public:
  template <Allocator Memory>
  [[nodiscard]] static std::string_view write(const InputConfiguration &input, std::size_t index, const ActionDescriptions<Memory> &descriptions, const runtime::config::RetainedCommandTabRegistry &commands, std::span<char> output) {
    if (index >= input.length) {
      throw std::runtime_error{"BindingNotFound"};
    }

    const auto &binding = input.configured[index];
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("index", index);
      object.member("prefixed", binding.prefixed);
      object.member("keys", [&](JsonWriter &value) {
        writeKeys(value, binding.sequence());
      });
      object.member("action", [&](JsonWriter &value) {
        ActionQuery::write(value, binding.action, descriptions, commands);
      });
    });

    return writer.view();
  }

private:
  static void writeKeys(JsonWriter &writer, std::span<const KeyChord> keys) {
    writer.array([&](JsonWriter &array) {
      for (const auto key : keys) {
        array.element([&](JsonWriter &value) {
          InputQuery::writeKey(value, key);
        });
      }
    });
  }
};

}
