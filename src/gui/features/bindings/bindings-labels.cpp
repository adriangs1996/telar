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
    constexpr auto modifiers = ds::Array<ModifierLabel, 4>{
        ModifierLabel{.modifier = KeyChord::Modifier::control, .pc = "Ctrl+", .mac = "⌃"},
        ModifierLabel{.modifier = KeyChord::Modifier::alt, .pc = "Alt+", .mac = "⌥"},
        ModifierLabel{.modifier = KeyChord::Modifier::shift, .pc = "Shift+", .mac = "⇧"},
        ModifierLabel{.modifier = KeyChord::Modifier::super, .pc = "Super+", .mac = "⌘"},
    };

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

    constexpr auto names = ds::Array<KeyName, 14>{
        KeyName{.key = KeyChord::Key::up, .pc = "Up", .mac = "↑"},
        KeyName{.key = KeyChord::Key::down, .pc = "Down", .mac = "↓"},
        KeyName{.key = KeyChord::Key::left, .pc = "Left", .mac = "←"},
        KeyName{.key = KeyChord::Key::right, .pc = "Right", .mac = "→"},
        KeyName{.key = KeyChord::Key::home, .pc = "Home", .mac = "↖"},
        KeyName{.key = KeyChord::Key::end, .pc = "End", .mac = "↘"},
        KeyName{.key = KeyChord::Key::erase, .pc = "Del", .mac = "⌦"},
        KeyName{.key = KeyChord::Key::page_up, .pc = "PgUp", .mac = "⇞"},
        KeyName{.key = KeyChord::Key::page_down, .pc = "PgDn", .mac = "⇟"},
        KeyName{.key = KeyChord::Key::enter, .pc = "Enter", .mac = "↩"},
        KeyName{.key = KeyChord::Key::escape, .pc = "Esc", .mac = "esc"},
        KeyName{.key = KeyChord::Key::backspace, .pc = "Backspace", .mac = "⌫"},
        KeyName{.key = KeyChord::Key::tab, .pc = "Tab", .mac = "⇥"},
        KeyName{.key = KeyChord::Key::back_tab, .pc = "Shift+Tab", .mac = "⇧⇥"},
    };

    for (const auto& name : names) {
      if (name.key == key.key) {
        text.append(style == KeyLabelStyle::mac ? name.mac : name.pc);

        return;
      }
    }
  }

}
