#pragma once

#include "telar_base/text/ascii.hpp"
#include "telar_config/key_chord.hpp"
#include "telar_config/value_constraints.hpp"
#include <cstring>
#include <utility>

namespace telar::runtime::config {

class KeyChordValidator {
  using Modifier = KeyChord::Modifier;
  using Key = KeyChord::Key;

public:
  static void validate(const lua::Value &value) {
    parse(value);
  }

  static KeyChord parse(const lua::Value &value) {
    auto remaining = value.string();
    KeyChord chord;
    bool has_key = false;
    for (;;) {
      const auto separator = remaining.find('+');
      const auto part = remaining.substr(0, separator);
      if (part.empty() || has_key) {
        value.fail("contains an empty key or a modifier after its key");
      }

      const auto modifier = identifyModifier(part);
      if (modifier != Modifier::none) {
        const auto bit = static_cast<unsigned>(modifier);
        if ((chord.modifiers & bit) != 0) {
          value.fail("repeats a modifier");
        }
        chord.modifiers |= bit;
      } else {
        parseKey(value, part, chord);
        has_key = true;
      }

      if (separator == std::string_view::npos) {
        break;
      }
      remaining.remove_prefix(separator + 1);
    }

    if (!has_key) {
      value.fail("has no key");
    }
    return chord;
  }

private:
  static bool matches(std::string_view text, std::string_view name) noexcept {
    return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) { return asciiLower(left) == right; });
  }

  static Modifier identifyModifier(std::string_view name) noexcept {
    if (matches(name, "ctrl") || matches(name, "control")) {
      return Modifier::control;
    }
    if (matches(name, "alt")) {
      return Modifier::alt;
    }
    if (matches(name, "shift")) {
      return Modifier::shift;
    }
    if (matches(name, "super") || matches(name, "cmd") || matches(name, "command")) {
      return Modifier::super;
    }
    return Modifier::none;
  }

  static void parseKey(const lua::Value &value, std::string_view name, KeyChord &chord) {
    constexpr std::pair<std::string_view, Key> named_keys[]{{"up", Key::up}, {"down", Key::down}, {"left", Key::left}, {"right", Key::right}, {"home", Key::home}, {"end", Key::end}, {"delete", Key::erase}, {"del", Key::erase}, {"pageup", Key::page_up}, {"page-up", Key::page_up}, {"pagedown", Key::page_down}, {"page-down", Key::page_down}, {"enter", Key::enter}, {"return", Key::enter}, {"escape", Key::escape}, {"esc", Key::escape}, {"backspace", Key::backspace}, {"tab", Key::tab}, {"backtab", Key::back_tab}};
    for (const auto &[known, key] : named_keys) {
      if (matches(name, known)) {
        chord.key = key;
        if (key == Key::tab && chord.modifiers == static_cast<unsigned>(Modifier::shift)) {
          chord.key = Key::back_tab;
          chord.modifiers = 0;
        }
        return;
      }
    }

    if (matches(name, "space")) {
      name = " ";
    } else if (matches(name, "plus")) {
      name = "+";
    }
    validateUtf8(name);
    const auto codepoints = std::ranges::count_if(name, [](unsigned char byte) { return (byte & 0xc0) != 0x80; });
    if (codepoints != 1) {
      value.fail("must name one key");
    }

    std::memcpy(&chord.character, name.data(), name.size());
    if (name.size() == 1 && (chord.has(Modifier::control) || chord.has(Modifier::super))) {
      chord.character = static_cast<unsigned char>(asciiLower(name.front()));
    }
    if (chord.has(Modifier::shift) && !chord.has(Modifier::super)) {
      const bool letter = name.size() == 1 && asciiLower(name.front()) >= 'a' && asciiLower(name.front()) <= 'z';
      if (chord.has(Modifier::control) || (!letter && name != " ")) {
        value.fail("cannot represent this shifted character");
      }
      chord.character = letter ? static_cast<unsigned char>(asciiLower(name.front()) - ('a' - 'A')) : ' ';
      chord.modifiers &= ~static_cast<unsigned>(Modifier::shift);
    }
  }
};

}
