#pragma once

#include <cstdint>

namespace telar::runtime::config {

struct KeyChord {
  enum class Key {
    character,
    up,
    down,
    left,
    right,
    home,
    end,
    erase,
    page_up,
    page_down,
    enter,
    escape,
    backspace,
    tab,
    back_tab
  };

  enum class Modifier : unsigned {
    none = 0,
    control = 1,
    alt = 2,
    shift = 4,
    super = 8
  };

  Key key = Key::character;
  std::uint32_t character = 0;
  unsigned modifiers = 0;

  bool has(Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }

  bool operator==(const KeyChord &) const = default;
};

}
