#pragma once

#include "core/unicode_scalar.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal_key.hpp"
#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <utility>

namespace telar::gui {

class KeyEncoder {
public:
  static constexpr std::size_t maximum_codepoint_fields = 3;
  static constexpr std::size_t codepoint_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
  static constexpr std::size_t modifier_digits = std::numeric_limits<std::uint8_t>::digits10 + 1;
  static constexpr std::size_t event_digits = 1;
  static constexpr std::size_t scalar_digits = 7;
  static constexpr std::size_t capacity = std::string_view{"\x1b[::;:;u"}.size() + (maximum_codepoint_fields * codepoint_digits) + modifier_digits + event_digits + scalar_digits;

  [[nodiscard]] std::string_view encode(const TerminalKey &key, const InputModes &modes) {
    used_ = 0;

    if (key.has(KeyChord::Modifier::super)) {
      return view();
    }

    const Encoding encoding{key, modes};
    if (key.phase == KeyPhase::release && !encoding.event) {
      return view();
    }

    if (encodeText(key, encoding)) {
      return view();
    }

    if (encoding.usesKitty(key)) {
      encodeKitty(key, encoding);
    } else if (key.phase != KeyPhase::release || reportsLegacyRelease(key.code)) {
      encodeLegacy(key, encoding, modes);
    }

    return view();
  }

private:
  using Code = KeyChord::Key;
  using Modifier = KeyChord::Modifier;

  enum class SequenceCode : std::uint8_t {
    cursor = 1,
    erase = 3,
    page_up = 5,
    page_down = 6,
  };

  static constexpr char escape = '\x1b';
  static constexpr char erase = '\x7f';

  static bool reportsLegacyRelease(Code code) noexcept {
    switch (code) {
    case Code::enter:
    case Code::backspace:
    case Code::tab:
    case Code::back_tab:
      return false;
    default:
      return true;
    }
  }

  struct Encoding {
    explicit Encoding(const TerminalKey &key, const InputModes &modes)
        : modifier(1 + (key.has(Modifier::shift) ? 1 : 0) + (key.has(Modifier::alt) ? 2 : 0) + (key.has(Modifier::control) ? 4 : 0)),
          flags(modes.kitty_keyboard_flags),
          cursor_keys(modes.cursor_keys) {
      if (has(KittyKeyboardFlag::report_events) && key.phase != KeyPhase::press) {
        event = static_cast<unsigned>(key.phase) + 1;
      }
    }

    [[nodiscard]] bool has(KittyKeyboardFlag flag) const noexcept {
      return (flags & static_cast<unsigned>(flag)) != 0;
    }

    [[nodiscard]] bool usesKitty(const TerminalKey &key) const noexcept {
      if (flags == 0) {
        return false;
      }

      if (key.code == Code::character || key.code == Code::escape) {
        return true;
      }

      return (key.code == Code::enter || key.code == Code::backspace || key.code == Code::tab) && (modifier != 1 || has(KittyKeyboardFlag::all_keys) || (has(KittyKeyboardFlag::report_events) && key.kitty.has_value()));
    }

    unsigned modifier;
    unsigned flags;
    bool cursor_keys;
    std::optional<unsigned> event;
  };

  [[nodiscard]] std::string_view view() const noexcept {
    return {bytes_.data(), used_};
  }

  void append(std::string_view text) {
    if (text.size() > bytes_.size() - used_) {
      throw std::length_error{"Encoded key exceeds its byte capacity"};
    }

    for (const auto byte : text) {
      bytes_[used_++] = byte;
    }
  }

  void byte(char value) {
    append({&value, 1});
  }

  void number(std::uint32_t value) {
    const auto encoded = std::to_chars(bytes_.data() + used_, bytes_.data() + bytes_.size(), value);
    if (encoded.ec != std::errc{}) {
      throw std::length_error{"Encoded key number exceeds its byte capacity"};
    }

    used_ = static_cast<std::size_t>(encoded.ptr - bytes_.data());
  }

  static std::uint32_t textCodepoint(const TerminalKey &key) {
    const auto codepoint = key.has(Modifier::shift) && key.kitty && key.kitty->shifted ? *key.kitty->shifted : key.codepoint;
    if (!Utf8Scalar::valid(codepoint)) {
      throw std::invalid_argument{"Key contains an invalid Unicode scalar"};
    }

    return codepoint;
  }

  bool encodeText(const TerminalKey &key, const Encoding &encoding) {
    if (key.code != Code::character || encoding.has(KittyKeyboardFlag::all_keys) || (encoding.has(KittyKeyboardFlag::report_events) && key.kitty) || key.has(Modifier::control) || key.has(Modifier::alt)) {
      return false;
    }

    if (key.phase != KeyPhase::release) {
      append(Utf8Scalar::encode(textCodepoint(key)).view());
    }

    return true;
  }

  static std::optional<std::uint32_t> associatedText(const TerminalKey &key, const Encoding &encoding) {
    if (!encoding.has(KittyKeyboardFlag::associated_text) || key.phase == KeyPhase::release || key.code != Code::character || key.has(Modifier::control) || key.has(Modifier::alt)) {
      return {};
    }

    constexpr std::uint32_t first_private_key = 57344;
    constexpr std::uint32_t last_private_key = 63743;
    if (key.kitty && key.kitty->primary >= first_private_key && key.kitty->primary <= last_private_key) {
      return {};
    }

    const auto codepoint = textCodepoint(key);
    constexpr std::uint32_t first_printable = 32;
    constexpr std::uint32_t first_c1_control = 127;
    constexpr std::uint32_t last_c1_control = 159;

    return codepoint < first_printable || (codepoint >= first_c1_control && codepoint <= last_c1_control) ? std::nullopt : std::optional{codepoint};
  }

  void kittyCodepoints(const TerminalKey &key, const Encoding &encoding) {
    if (key.kitty) {
      number(key.kitty->primary);
      if (encoding.has(KittyKeyboardFlag::alternate_keys) && (key.kitty->shifted || key.kitty->base)) {
        byte(':');
        if (key.kitty->shifted) {
          number(*key.kitty->shifted);
        }

        if (key.kitty->base) {
          byte(':');
          number(*key.kitty->base);
        }
      }

      return;
    }

    switch (key.code) {
    case Code::character:
      if (!Utf8Scalar::valid(key.codepoint)) {
        throw std::invalid_argument{"Key contains an invalid Unicode scalar"};
      }

      number(key.codepoint);
      break;
    case Code::enter:
      number('\r');
      break;
    case Code::escape:
      number(escape);
      break;
    case Code::backspace:
      number(erase);
      break;
    case Code::tab:
      number('\t');
      break;
    default:
      throw std::invalid_argument{"Key has no Kitty codepoint"};
    }
  }

  void encodeKitty(const TerminalKey &key, const Encoding &encoding) {
    const auto associated = associatedText(key, encoding);
    append("\x1b[");
    kittyCodepoints(key, encoding);
    if (encoding.modifier != 1 || encoding.event || associated) {
      byte(';');
      number(encoding.modifier);
    }

    if (encoding.event) {
      byte(':');
      number(*encoding.event);
    }

    if (associated) {
      byte(';');
      number(*associated);
    }

    byte('u');
  }

  void altText(const TerminalKey &key, std::string_view text) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    append(text);
  }

  static std::optional<char> controlByte(std::uint32_t codepoint) noexcept {
    constexpr unsigned control_mask = 0x1f;
    if ((codepoint >= 'a' && codepoint <= 'z') || (codepoint >= 'A' && codepoint <= 'Z')) {
      return static_cast<char>(codepoint & control_mask);
    }

    constexpr auto controls = std::to_array<std::pair<std::uint32_t, char>>({
        {' ', '\0'},
        {'@', '\0'},
        {'2', '\0'},
        {'[', '\x1b'},
        {'3', '\x1b'},
        {'\\', '\x1c'},
        {'4', '\x1c'},
        {']', '\x1d'},
        {'5', '\x1d'},
        {'^', '\x1e'},
        {'~', '\x1e'},
        {'6', '\x1e'},
        {'_', '\x1f'},
        {'/', '\x1f'},
        {'7', '\x1f'},
        {'?', erase},
        {'8', erase},
    });
    for (const auto &[known, value] : controls) {
      if (codepoint == known) {
        return value;
      }
    }

    return {};
  }

  void legacyCharacter(const TerminalKey &key) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    const auto control = key.has(Modifier::control) ? controlByte(key.codepoint) : std::nullopt;
    if (control) {
      byte(*control);
    } else {
      append(Utf8Scalar::encode(key.codepoint).view());
    }
  }

  void sequence(SequenceCode code, char final, const Encoding &encoding) {
    if (code == SequenceCode::cursor && !encoding.event && encoding.modifier == 1) {
      append(encoding.cursor_keys && !encoding.has(KittyKeyboardFlag::report_events) ? "\x1bO" : "\x1b[");
      byte(final);

      return;
    }

    append("\x1b[");
    number(static_cast<unsigned>(code));
    if (encoding.modifier != 1 || encoding.event) {
      byte(';');
      number(encoding.modifier);
    }

    if (encoding.event) {
      byte(':');
      number(*encoding.event);
    }

    byte(final);
  }

  void encodeLegacy(const TerminalKey &key, const Encoding &encoding, const InputModes &modes) {
    switch (key.code) {
    case Code::character:
      legacyCharacter(key);
      break;
    case Code::up:
      sequence(SequenceCode::cursor, 'A', encoding);
      break;
    case Code::down:
      sequence(SequenceCode::cursor, 'B', encoding);
      break;
    case Code::right:
      sequence(SequenceCode::cursor, 'C', encoding);
      break;
    case Code::left:
      sequence(SequenceCode::cursor, 'D', encoding);
      break;
    case Code::home:
      sequence(SequenceCode::cursor, 'H', encoding);
      break;
    case Code::end:
      sequence(SequenceCode::cursor, 'F', encoding);
      break;
    case Code::erase:
      sequence(SequenceCode::erase, '~', encoding);
      break;
    case Code::page_up:
      sequence(SequenceCode::page_up, '~', encoding);
      break;
    case Code::page_down:
      sequence(SequenceCode::page_down, '~', encoding);
      break;
    case Code::enter:
      if (modes.modify_other_keys_2 && encoding.modifier != 1) {
        append("\x1b[27;");
        number(encoding.modifier);
        append(";13~");
      } else {
        altText(key, "\r");
      }

      break;
    case Code::escape:
      altText(key, "\x1b");
      break;
    case Code::backspace:
      altText(key, key.has(Modifier::control) ? "\x08" : "\x7f");
      break;
    case Code::tab:
      altText(key, key.has(Modifier::shift) ? "\x1b[Z" : "\t");
      break;
    case Code::back_tab:
      altText(key, "\x1b[Z");
      break;
    }
  }

  std::array<char, capacity> bytes_{};
  std::size_t used_ = 0;
};

}
