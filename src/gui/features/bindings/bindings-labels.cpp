module telar.gui.features.bindings;

import std;

import telar.base.text;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::bindings {

  KeyLabel::Text KeyLabel::chord(ds::Option<KeyChord> prefix, KeyChord key, KeyLabelStyle style) {
    Text text;

    if (prefix) {
      append(text, *prefix, style);
      text.append(" ");
    }

    append(text, key, style);

    return text;
  }

  void KeyLabel::append(Text& text, KeyChord key, KeyLabelStyle style) {
    constexpr auto modifiers = std::to_array<ModifierLabel>({
        {.modifier = KeyChord::Modifier::control, .pc = "Ctrl+", .mac = "⌃"},
        {.modifier = KeyChord::Modifier::alt, .pc = "Alt+", .mac = "⌥"},
        {.modifier = KeyChord::Modifier::shift, .pc = "Shift+", .mac = "⇧"},
        {.modifier = KeyChord::Modifier::super, .pc = "Super+", .mac = "⌘"},
    });

    for (const auto& modifier : modifiers) {
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

    for (const auto& name : names) {
      if (name.key == key.key) {
        text.append(style == KeyLabelStyle::mac ? name.mac : name.pc);

        return;
      }
    }
  }

}
