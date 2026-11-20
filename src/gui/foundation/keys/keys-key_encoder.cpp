module telar.gui.foundation.keys;

import std;

import telar.base.text;
import telar.config.client;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline keys {

  std::uint32_t KeyCharacter::pack(std::uint32_t codepoint) {
    return std::bit_cast<std::uint32_t>(Utf8Scalar::encode(codepoint).bytes);
  }

  Utf8Scalar KeyCharacter::text(std::uint32_t storage) noexcept {
    Utf8Scalar result;

    result.bytes = std::bit_cast<ds::Array<char, sizeof(storage)>>(storage);
    const auto* const terminator = std::ranges::find(result.bytes, '\0');

    result.length = std::max<std::size_t>(1, static_cast<std::size_t>(terminator - result.bytes.begin()));

    return result;
  }

  std::uint32_t KeyCharacter::codepoint(std::uint32_t storage) {
    return Utf8Scalar::decode(text(storage).view());
  }

  bool TerminalKey::has(KeyChord::Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }

  std::string_view KeyEncoder::alternateScroll(bool upward, const InputModes& modes) {
    return encode({.code = upward ? KeyChord::Key::up : KeyChord::Key::down}, {.cursor_keys = modes.cursor_keys});
  }

  std::string_view KeyEncoder::encode(const TerminalKey& key, const InputModes& modes) {
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

  bool KeyEncoder::reportsLegacyRelease(Code code) noexcept {
    switch (code) {
    case Code::enter:
    case Code::backspace:
    case Code::tab:
    case Code::back_tab:
      return false;
    case Code::character:
    case Code::up:
    case Code::down:
    case Code::left:
    case Code::right:
    case Code::home:
    case Code::end:
    case Code::erase:
    case Code::page_up:
    case Code::page_down:
    case Code::escape:
      break;
    }

    // The other keys, and one outside the enum.
    return true;
  }

  KeyEncoder::Encoding::Encoding(const TerminalKey& key, const InputModes& modes)
      : modifier(1 + (key.has(Modifier::shift) ? 1 : 0) + (key.has(Modifier::alt) ? 2 : 0) + (key.has(Modifier::control) ? 4 : 0)),
        flags(modes.kitty_keyboard_flags),
        cursor_keys(modes.cursor_keys) {
    if (has(KittyKeyboardFlag::report_events) && key.phase != KeyPhase::press) {
      event = static_cast<unsigned>(key.phase) + 1;
    }
  }

  bool KeyEncoder::Encoding::has(KittyKeyboardFlag flag) const noexcept {
    return (flags & static_cast<unsigned>(flag)) != 0;
  }

  bool KeyEncoder::Encoding::usesKitty(const TerminalKey& key) const noexcept {
    if (flags == 0) {
      return false;
    }

    if (key.code == Code::character || key.code == Code::escape) {
      return true;
    }

    return (key.code == Code::enter || key.code == Code::backspace || key.code == Code::tab) && (modifier != 1 || has(KittyKeyboardFlag::all_keys) || (has(KittyKeyboardFlag::report_events) && key.kitty.hasValue()));
  }

  std::string_view KeyEncoder::view() const noexcept {
    return {bytes_.data(), used_};
  }

  void KeyEncoder::append(std::string_view text) {
    if (text.size() > bytes_.size() - used_) {
      throw std::length_error{"Encoded key exceeds its byte capacity"};
    }

    for (const auto byte : text) {
      bytes_.atMut(used_++) = byte;
    }
  }

  void KeyEncoder::byte(char value) {
    append({&value, 1});
  }

  void KeyEncoder::number(std::uint32_t value) {
    auto room = bytes_.viewMut().subspan(used_); // NOLINT(misc-const-correctness): a span written through, which tbc's deep const forbids marking const
    const auto encoded = std::to_chars(room.data(), std::to_address(room.end()), value);
    if (encoded.ec == std::errc::value_too_large) {
      throw std::length_error{"Encoded key number exceeds its byte capacity"};
    }

    used_ = static_cast<std::size_t>(encoded.ptr - bytes_.data());
  }

  std::uint32_t KeyEncoder::textCodepoint(const TerminalKey& key) {
    const auto codepoint = key.has(Modifier::shift) && key.kitty && key.kitty->shifted ? *key.kitty->shifted : key.codepoint;
    if (!Utf8Scalar::valid(codepoint)) {
      throw std::invalid_argument{"Key contains an invalid Unicode scalar"};
    }

    return codepoint;
  }

  bool KeyEncoder::encodeText(const TerminalKey& key, const Encoding& encoding) {
    if (key.code != Code::character || encoding.has(KittyKeyboardFlag::all_keys) || (encoding.has(KittyKeyboardFlag::report_events) && key.kitty) || key.has(Modifier::control) || key.has(Modifier::alt)) {
      return false;
    }

    if (key.phase != KeyPhase::release) {
      append(Utf8Scalar::encode(textCodepoint(key)).view());
    }

    return true;
  }

  ds::Option<std::uint32_t> KeyEncoder::associatedText(const TerminalKey& key, const Encoding& encoding) {
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

    return codepoint < first_printable || (codepoint >= first_c1_control && codepoint <= last_c1_control) ? ds::none : ds::Option{codepoint};
  }

  void KeyEncoder::kittyCodepoints(const TerminalKey& key, const Encoding& encoding) {
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
    case Code::up:
    case Code::down:
    case Code::left:
    case Code::right:
    case Code::home:
    case Code::end:
    case Code::erase:
    case Code::page_up:
    case Code::page_down:
    case Code::back_tab:
      throw std::invalid_argument{"Key has no Kitty codepoint"};
    }
  }

  void KeyEncoder::encodeKitty(const TerminalKey& key, const Encoding& encoding) {
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

  void KeyEncoder::altText(const TerminalKey& key, std::string_view text) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    append(text);
  }

  ds::Option<char> KeyEncoder::controlByte(std::uint32_t codepoint) noexcept {
    constexpr unsigned control_mask = 0x1f;

    if ((codepoint >= 'a' && codepoint <= 'z') || (codepoint >= 'A' && codepoint <= 'Z')) {
      return static_cast<char>(codepoint & control_mask);
    }

    constexpr auto controls = ds::Array<std::pair<std::uint32_t, char>, 17>{
        {
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
        },
    };

    for (const auto& [known, value] : controls) {
      if (codepoint == known) {
        return value;
      }
    }

    return {};
  }

  void KeyEncoder::legacyCharacter(const TerminalKey& key) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    const auto control = key.has(Modifier::control) ? controlByte(key.codepoint) : ds::none;
    if (control) {
      byte(*control);
    } else {
      append(Utf8Scalar::encode(key.codepoint).view());
    }
  }

  void KeyEncoder::sequence(SequenceCode code, char final, const Encoding& encoding) {
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

  void KeyEncoder::encodeLegacy(const TerminalKey& key, const Encoding& encoding, const InputModes& modes) {
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

}
