#pragma once

#include "binding.hpp"
#include "key_event.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

enum class KittyKeyboardFlag : std::uint8_t {
  disambiguate = 1,
  report_events = 2,
  alternate_keys = 4,
  all_keys = 8,
  associated_text = 16,
};

struct KittyCodepoints {
  std::uint32_t primary = 0;
  std::optional<std::uint32_t> shifted = std::nullopt;
  std::optional<std::uint32_t> base = std::nullopt;
};

struct TerminalKey {
  KeyChord::Key code = KeyChord::Key::character;
  std::uint32_t codepoint = 0;
  unsigned modifiers = 0;
  KeyPhase phase = KeyPhase::press;
  std::optional<KittyCodepoints> kitty = std::nullopt;

  [[nodiscard]] bool has(KeyChord::Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }
};

}
