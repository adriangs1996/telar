#pragma once

#include <compare> // IWYU pragma: export
#include <cstdint>
#include <expected>
#include <string_view>

namespace keybindings {
  enum class Modifier : std::uint8_t {
    Shift = 1,
    Alt = 2,
    Control = 4,
    Super = 8
  };

  enum class KeyCode : std::uint8_t {
    Character,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    Delete,
    PageUp,
    PageDown,
    Enter,
    Escape,
    Backspace,
    Tab,
    BackTab
  };

  struct Chord {
    std::uint8_t modifiers = 0;
    KeyCode code = KeyCode::Escape;
    char32_t character = 0;

    bool has(Modifier modifier) const noexcept;
    bool hasCommandModifier() const noexcept;
    auto operator<=>(const Chord &) const = default;
  };

  // Parses one chord without allocating, including on invalid native input.
  std::expected<Chord, const char *> parseChord(std::string_view text) noexcept;
} // namespace keybindings
