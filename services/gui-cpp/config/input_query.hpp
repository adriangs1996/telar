#pragma once

#include "core/json_writer.hpp"
#include "core/unicode_scalar.hpp"
#include "input/binding.hpp"
#include "input/configuration.hpp"
#include <array>
#include <bit>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class InputQuery {
public:
  [[nodiscard]] static std::string_view write(const InputConfiguration &input, std::span<char> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("prefix", [&](JsonWriter &value) {
        writeKey(value, input.prefix);
      });
      object.member("sequence_timeout_ns", input.sequence_timeout_ns);
      object.member("binding_count", input.length);
    });

    return writer.view();
  }

  static void writeKey(JsonWriter &writer, KeyChord key) {
    writer.object([&](JsonWriter &object) {
      object.member("code", [&](JsonWriter &value) {
        writeCode(value, key);
      });
      object.member("mods", [&](JsonWriter &value) {
        value.object([&](JsonWriter &modifiers) {
          modifiers.member("shift", key.has(KeyChord::Modifier::shift));
          modifiers.member("alt", key.has(KeyChord::Modifier::alt));
          modifiers.member("ctrl", key.has(KeyChord::Modifier::control));
          modifiers.member("super", key.has(KeyChord::Modifier::super));
        });
      });
      object.member("phase", "press");
      object.member("physical", nullptr);
      object.member("kitty", nullptr);
    });
  }

private:
  static void writeCode(JsonWriter &writer, KeyChord key) {
    writer.object([&](JsonWriter &object) {
      if (key.key != KeyChord::Key::character) {
        object.member(keyName(key.key), writeEmptyObject);

        return;
      }

      object.member("char", [&](JsonWriter &value) {
        writeCharacter(value, key);
      });
    });
  }

  static void writeEmptyObject(JsonWriter &writer) {
    writer.object([](JsonWriter &) {
    });
  }

  static void writeCharacter(JsonWriter &writer, KeyChord key) {
    const auto bytes = std::bit_cast<std::array<char, sizeof(key.character)>>(key.character);
    const auto first = static_cast<unsigned char>(bytes.front());
    std::size_t length = 1;
    while (length < Utf8Scalar::leading_prefixes.size() && first >= Utf8Scalar::leading_prefixes[length]) {
      ++length;
    }

    writer.object([&](JsonWriter &character) {
      character.member("bytes", std::string_view{bytes.data(), bytes.size()});
      character.member("len", length);
    });
  }

  static std::string_view keyName(KeyChord::Key key) {
    constexpr std::array names{"char", "up", "down", "left", "right", "home", "end", "delete", "page_up", "page_down", "enter", "escape", "backspace", "tab", "back_tab"};
    const auto index = static_cast<std::size_t>(key);
    if (index >= names.size()) {
      throw std::invalid_argument{"Unknown key code"};
    }

    return names[index];
  }
};

}
