#pragma once

#include "core/unicode_scalar.hpp"
#include "input/binding.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

enum class KeyLabelStyle : std::uint8_t {
  pc,
  mac,
};

class KeyLabel {
public:
  static constexpr std::size_t capacity = 64;
  using Text = BoundedText<capacity>;

  [[nodiscard]] static Text chord(std::optional<KeyChord> prefix, KeyChord key, KeyLabelStyle style) {
    Text text;
    if (prefix) {
      append(text, *prefix, style);
      text.append(" ");
    }

    append(text, key, style);

    return text;
  }

private:
  struct ModifierLabel {
    KeyChord::Modifier modifier;
    std::string_view pc;
    std::string_view mac;
  };

  struct KeyName {
    KeyChord::Key key;
    std::string_view pc;
    std::string_view mac;
  };

  static void append(Text &text, KeyChord key, KeyLabelStyle style) {
    constexpr auto modifiers = std::to_array<ModifierLabel>({
        {.modifier = KeyChord::Modifier::control, .pc = "Ctrl+", .mac = "⌃"},
        {.modifier = KeyChord::Modifier::alt, .pc = "Alt+", .mac = "⌥"},
        {.modifier = KeyChord::Modifier::shift, .pc = "Shift+", .mac = "⇧"},
        {.modifier = KeyChord::Modifier::super, .pc = "Super+", .mac = "⌘"},
    });
    for (const auto &modifier : modifiers) {
      if (key.has(modifier.modifier)) {
        text.append(style == KeyLabelStyle::mac ? modifier.mac : modifier.pc);
      }
    }

    if (key.key == KeyChord::Key::character) {
      constexpr auto case_offset = 'a' - 'A';
      const auto ascii_lower = key.character >= 'a' && key.character <= 'z';
      const auto character = style == KeyLabelStyle::mac && ascii_lower ? key.character - case_offset : key.character;
      text.append(Utf8Scalar::encode(character).view());

      return;
    }

    constexpr auto names = std::to_array<KeyName>({
        {.key = KeyChord::Key::up, .pc = "Up", .mac = "↑"},
        {.key = KeyChord::Key::down, .pc = "Down", .mac = "↓"},
        {.key = KeyChord::Key::left, .pc = "Left", .mac = "←"},
        {.key = KeyChord::Key::right, .pc = "Right", .mac = "→"},
        {.key = KeyChord::Key::home, .pc = "Home", .mac = "↖"},
        {.key = KeyChord::Key::end, .pc = "End", .mac = "↘"},
        {.key = KeyChord::Key::erase, .pc = "Del", .mac = "⌦"},
        {.key = KeyChord::Key::page_up, .pc = "PgUp", .mac = "⇞"},
        {.key = KeyChord::Key::page_down, .pc = "PgDn", .mac = "⇟"},
        {.key = KeyChord::Key::enter, .pc = "Enter", .mac = "↩"},
        {.key = KeyChord::Key::escape, .pc = "Esc", .mac = "esc"},
        {.key = KeyChord::Key::backspace, .pc = "Backspace", .mac = "⌫"},
        {.key = KeyChord::Key::tab, .pc = "Tab", .mac = "⇥"},
        {.key = KeyChord::Key::back_tab, .pc = "Shift+Tab", .mac = "⇧⇥"},
    });
    for (const auto &name : names) {
      if (name.key == key.key) {
        text.append(style == KeyLabelStyle::mac ? name.mac : name.pc);

        return;
      }
    }
  }
};

}
