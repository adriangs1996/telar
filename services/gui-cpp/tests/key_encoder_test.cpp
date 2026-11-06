#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <algorithm>
#include <span>
#include <tuple>
#include "telar_client/serializers/telar_frame.hpp"
#include <charconv>
#include <limits>
#include <system_error>
#include <utility>
#include "telar_client/codecs/telar_wire.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.core.unicode_scalar;
import telar.gui.input.key_encoder;

namespace {

using namespace telar::gui;
using Modifier = KeyChord::Modifier;
using Code = KeyChord::Key;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void unicodeScalars() {
  for (std::uint32_t codepoint = 0; codepoint <= Utf8Scalar::maximum_codepoint; ++codepoint) {
    if (Utf8Scalar::valid(codepoint)) {
      const auto encoded = Utf8Scalar::encode(codepoint);
      require(Utf8Scalar::decode(encoded.view()) == codepoint, "every Unicode scalar must round-trip without allocation");
    }
  }

  constexpr auto invalid = std::to_array<std::string_view>({"", "ab", "\x80", "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf0\x80\x80\x80", "\xf0\x9f", "\xf0\x9f\x8c\x20"});
  for (const auto text : invalid) {
    bool rejected = false;
    try {
      static_cast<void>(Utf8Scalar::decode(text));
    } catch (const std::invalid_argument &) {
      rejected = true;
    }

    require(rejected, "invalid, truncated, overlong or multiple UTF-8 scalars must be rejected");
  }
}

void legacyControls() {
  KeyEncoder encoder;
  require(encoder.encode({.code = Code::backspace, .modifiers = static_cast<unsigned>(Modifier::control)}, {}) == "\x08", "legacy Ctrl+Backspace must emit Backspace");
  require(encoder.encode({.codepoint = '2', .modifiers = static_cast<unsigned>(Modifier::control)}, {}) == std::string_view{"\0", 1}, "legacy Ctrl+2 must preserve its NUL byte");
  require(encoder.encode({.codepoint = '8', .modifiers = static_cast<unsigned>(Modifier::control)}, {}) == "\x7f", "legacy Ctrl+8 must emit DEL");
  require(encoder.encode({.code = Code::tab, .modifiers = static_cast<unsigned>(Modifier::alt) | static_cast<unsigned>(Modifier::shift)}, {}) == "\x1b\x1b[Z", "Alt+Shift+Tab must preserve the Alt escape prefix");
  require(encoder.encode({.code = Code::enter, .modifiers = static_cast<unsigned>(Modifier::control)}, {.modify_other_keys_2 = true}) == "\x1b[27;5;13~", "modifyOtherKeys level two must encode modified Enter");
  require(encoder.encode({.codepoint = 'c', .modifiers = static_cast<unsigned>(Modifier::control)}, {.modify_other_keys_2 = true}) == "\x03", "modifyOtherKeys must retain the original legacy character behavior");
}

void kittyEvents() {
  KeyEncoder encoder;
  constexpr auto report_events = static_cast<telar::Byte>(KittyKeyboardFlag::report_events);
  constexpr auto all_keys = static_cast<telar::Byte>(KittyKeyboardFlag::all_keys);
  constexpr auto alternate_keys = static_cast<telar::Byte>(KittyKeyboardFlag::alternate_keys);
  require(encoder.encode({.codepoint = 'c', .modifiers = static_cast<unsigned>(Modifier::control)}, {.kitty_keyboard_flags = report_events}) == "\x1b[99;5u", "Kitty presses must omit the default event field");
  require(encoder.encode({.codepoint = 'c', .modifiers = static_cast<unsigned>(Modifier::control), .phase = KeyPhase::repeat}, {.kitty_keyboard_flags = report_events}) == "\x1b[99;5:2u", "Kitty repeats must report event two");
  require(encoder.encode({.codepoint = 'a', .phase = KeyPhase::release}, {.kitty_keyboard_flags = report_events}).empty(), "text-only keys without metadata must not acquire unmatched releases");
  require(encoder.encode({.codepoint = 'a', .phase = KeyPhase::release}, {.kitty_keyboard_flags = report_events | all_keys}) == "\x1b[97;1:3u", "Kitty all-key releases must report event three");
  require(encoder.encode({.code = Code::up}, {.cursor_keys = true, .kitty_keyboard_flags = report_events}) == "\x1b[A", "Kitty event reporting must override application cursor mode");
  require(encoder.encode({.codepoint = 'a', .modifiers = static_cast<unsigned>(Modifier::super)}, {.kitty_keyboard_flags = all_keys}).empty(), "unbound Super chords belong to the GUI");
  require(encoder.encode({.code = Code::escape}, {.kitty_keyboard_flags = alternate_keys}) == "\x1b[27u", "Escape must use Kitty whenever its protocol is active");
}

void kittyMetadata() {
  KeyEncoder encoder;
  constexpr telar::Byte all_flags = 31;
  constexpr std::uint32_t base_codepoint = 113;
  require(encoder.encode({.codepoint = 'a', .kitty = KittyCodepoints{.primary = 'a', .base = base_codepoint}}, {.kitty_keyboard_flags = all_flags}) == "\x1b[97::113;1;97u", "a missing shifted codepoint must retain its empty Kitty field");
  require(encoder.encode({.codepoint = 'a', .modifiers = static_cast<unsigned>(Modifier::shift), .kitty = KittyCodepoints{.primary = 'a', .shifted = 'A'}}, {.kitty_keyboard_flags = all_flags}) == "\x1b[97:65;2;65u", "associated text must use the shifted semantic character");
  require(encoder.encode({.codepoint = 'a', .modifiers = static_cast<unsigned>(Modifier::alt)}, {.kitty_keyboard_flags = all_flags}) == "\x1b[97;3u", "Alt chords must not carry associated text");
  constexpr auto maximum = std::numeric_limits<std::uint32_t>::max();
  const auto maximal = encoder.encode({.codepoint = Utf8Scalar::maximum_codepoint, .phase = KeyPhase::repeat, .kitty = KittyCodepoints{.primary = maximum, .shifted = maximum, .base = maximum}}, {.kitty_keyboard_flags = all_flags});
  require(maximal == "\x1b[4294967295:4294967295:4294967295;1:2;1114111u" && maximal.size() <= KeyEncoder::capacity, "the fixed encoder capacity must admit full-width Kitty fields");
}

}

int main() {
  try {
    unicodeScalars();
    legacyControls();
    kittyEvents();
    kittyMetadata();
    std::puts("gui-key-encoder: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-key-encoder: " << error.what() << '\n';

    return 1;
  }
}
