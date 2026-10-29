#pragma once

#include "core/unicode_scalar.hpp"
#include "input/binding.hpp"
#include "input/key_character.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct ModeKeyLabel {
  static constexpr std::size_t capacity = 48;
  using Text = BoundedText<capacity>;

  [[nodiscard]] static Text format(KeyChord key) {
    Text result;
    if (key.has(KeyChord::Modifier::control)) {
      result.append("Ctrl+");
    }

    if (key.has(KeyChord::Modifier::alt)) {
      result.append("Alt+");
    }

    if (key.has(KeyChord::Modifier::shift)) {
      result.append("Shift+");
    }

    if (key.key == KeyChord::Key::character) {
      const auto text = KeyCharacter::text(key.character);
      static_cast<void>(Utf8Scalar::decode(text.view()));
      result.append(text.view());
    } else {
      result.append(name(key.key));
    }

    return result;
  }

private:
  [[nodiscard]] static std::string_view name(KeyChord::Key key) noexcept {
    switch (key) {
    case KeyChord::Key::up:
      return "Up";
    case KeyChord::Key::down:
      return "Down";
    case KeyChord::Key::left:
      return "Left";
    case KeyChord::Key::right:
      return "Right";
    case KeyChord::Key::home:
      return "Home";
    case KeyChord::Key::end:
      return "End";
    case KeyChord::Key::erase:
      return "Del";
    case KeyChord::Key::page_up:
      return "PgUp";
    case KeyChord::Key::page_down:
      return "PgDn";
    case KeyChord::Key::enter:
      return "Enter";
    case KeyChord::Key::escape:
      return "Esc";
    case KeyChord::Key::backspace:
      return "Backspace";
    case KeyChord::Key::tab:
      return "Tab";
    case KeyChord::Key::back_tab:
      return "BackTab";
    case KeyChord::Key::character:
      return {};
    }

    return {};
  }
};

}
