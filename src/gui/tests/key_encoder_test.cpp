#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.core.unicode_scalar;
import telar.gui.input.key_encoder;

namespace {

  using namespace telar::gui;
  using Modifier = KeyChord::Modifier;
  using Code = KeyChord::Key;

  void require(bool condition, const char* message) {
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
      } catch (const std::invalid_argument&) {
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

  // Every encoding over a fixed sweep of keys, modifiers, phases and modes, folded into one digest,
  // so any byte the encoder changes fails here. `golden` was taken from the encoder as it is.
  std::uint64_t sweepDigest() {
    KeyEncoder encoder;
    std::uint64_t digest = 14695981039346656037ULL;
    const auto fold = [&](std::string_view bytes) {
      for (const auto byte : bytes) {
        digest = (digest ^ static_cast<unsigned char>(byte)) * 1099511628211ULL;
      }

      digest = (digest ^ 0xffU) * 1099511628211ULL;
    };

    constexpr auto codepoints = std::to_array<std::uint32_t>({'a', 'A', 'c', 'z', '2', '8', ' ', '@', '[', '\\', ']', '^', '_', '/', '?', '~', 0xe9, 0x4e2d, 0x1f600});
    constexpr auto kitty_flags = std::to_array<telar::Byte>({0, 1, 2, 3, 8, 10, 31});

    for (const auto flags : kitty_flags) {
      for (unsigned mode = 0; mode < 8; ++mode) {
        const telar::InputModes modes{.cursor_keys = (mode & 1U) != 0, .keypad_keys = (mode & 2U) != 0, .kitty_keyboard_flags = flags, .modify_other_keys_2 = (mode & 4U) != 0};

        for (unsigned modifiers = 0; modifiers < 16; ++modifiers) {
          for (const auto phase : {KeyPhase::press, KeyPhase::repeat, KeyPhase::release}) {
            for (auto code = static_cast<unsigned>(Code::up); code <= static_cast<unsigned>(Code::back_tab); ++code) {
              fold(encoder.encode({.code = static_cast<Code>(code), .modifiers = modifiers, .phase = phase}, modes));
            }

            for (const auto codepoint : codepoints) {
              fold(encoder.encode({.codepoint = codepoint, .modifiers = modifiers, .phase = phase}, modes));
              fold(encoder.encode({.codepoint = codepoint, .modifiers = modifiers, .phase = phase, .kitty = KittyCodepoints{.primary = codepoint, .shifted = codepoint + 1, .base = 'q'}}, modes));
            }
          }
        }
      }
    }

    return digest;
  }

  // Alternate scroll sends Up or Down as the cursor key mode encodes them, and never in a keyboard
  // protocol the application asked for typed keys.
  void alternateScroll() {
    KeyEncoder encoder;

    require(encoder.alternateScroll(true, {}) == "\x1b[A" && encoder.alternateScroll(false, {}) == "\x1b[B", "alternate scroll must send normal cursor keys");
    require(encoder.alternateScroll(true, {.cursor_keys = true}) == "\x1bOA" && encoder.alternateScroll(false, {.cursor_keys = true}) == "\x1bOB", "alternate scroll must honor application cursor keys");
    require(encoder.alternateScroll(true, {.kitty_keyboard_flags = 31, .modify_other_keys_2 = true}) == "\x1b[A", "alternate scroll must ignore keyboard protocols");
  }

  void golden() {
    const auto digest = sweepDigest();
    constexpr std::uint64_t expected = 10501462004054449213ULL;
    if (digest != expected) {
      std::fprintf(stderr, "gui-key-encoder: sweep digest %llu\n", static_cast<unsigned long long>(digest));
    }

    require(digest == expected, "the key encoder's bytes must match the golden sweep");
  }

}

int main() {
  try {
    unicodeScalars();
    legacyControls();
    kittyEvents();
    kittyMetadata();
    alternateScroll();
    golden();
    std::puts("gui-key-encoder: passed");
  } catch (const std::exception& error) {
    std::cerr << "gui-key-encoder: " << error.what() << '\n';

    return 1;
  }
}
