module telar.gui.input.key_encoder;

import std;
import telar.base.text;
import telar.gui.foundation.core;

namespace telar::gui {

  int compareChords(KeyChord left, KeyChord right) noexcept {
    const auto left_value = std::tie(left.key, left.character, left.modifiers);
    const auto right_value = std::tie(right.key, right.character, right.modifiers);

    if (left_value < right_value) {
      return -1;
    }

    return static_cast<int>(left_value > right_value);
  }

  std::optional<KeyLeases::Owner> KeyLeases::owner(std::uint64_t physical) const noexcept {
    const auto index = find(physical);
    if (index == count_) {
      return std::nullopt;
    }

    return leases_[index].owner;
  }

  bool KeyLeases::acquire(std::uint64_t physical) noexcept {
    auto index = find(physical);
    if (index == count_) {
      if (count_ == leases_.size()) {
        ++overflow_;

        return false;
      }

      index = count_++;
    }

    leases_[index] = {.physical = physical, .owner = Owner::binding};

    return true;
  }

  void KeyLeases::transfer(std::uint64_t physical) noexcept {
    const auto index = find(physical);
    if (index != count_) {
      leases_[index].owner = Owner::application;
    }
  }

  std::optional<KeyLeases::Owner> KeyLeases::release(std::uint64_t physical) noexcept {
    const auto index = find(physical);
    if (index == count_) {
      return std::nullopt;
    }

    const auto owner = leases_[index].owner;

    leases_[index] = leases_[--count_];

    return owner;
  }

  void KeyLeases::clear() noexcept {
    count_ = 0;
  }

  std::uint64_t KeyLeases::overflowCount() const noexcept {
    return overflow_;
  }

  // Physical key 0 is no key, so it is never held.
  std::size_t KeyLeases::find(std::uint64_t physical) const noexcept {
    const auto held = std::span{leases_}.first(count_);
    const auto found = std::ranges::find(held, physical, &Lease::physical);

    return physical == 0 ? count_ : static_cast<std::size_t>(found - held.begin());
  }

  std::uint32_t KeyCharacter::pack(std::uint32_t codepoint) {
    return std::bit_cast<std::uint32_t>(Utf8Scalar::encode(codepoint).bytes);
  }

  Utf8Scalar KeyCharacter::text(std::uint32_t storage) noexcept {
    Utf8Scalar result;

    result.bytes = std::bit_cast<std::array<char, sizeof(storage)>>(storage);
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

  std::string_view KeyEncoder::alternateScroll(bool up, const InputModes& modes) {
    return encode({.code = up ? KeyChord::Key::up : KeyChord::Key::down}, {.cursor_keys = modes.cursor_keys});
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
    default:
      return true;
    }
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

    return (key.code == Code::enter || key.code == Code::backspace || key.code == Code::tab) && (modifier != 1 || has(KittyKeyboardFlag::all_keys) || (has(KittyKeyboardFlag::report_events) && key.kitty.has_value()));
  }

  std::string_view KeyEncoder::view() const noexcept {
    return {bytes_.data(), used_};
  }

  void KeyEncoder::append(std::string_view text) {
    if (text.size() > bytes_.size() - used_) {
      throw std::length_error{"Encoded key exceeds its byte capacity"};
    }

    for (const auto byte : text) {
      bytes_[used_++] = byte;
    }
  }

  void KeyEncoder::byte(char value) {
    append({&value, 1});
  }

  void KeyEncoder::number(std::uint32_t value) {
    const auto encoded = std::to_chars(bytes_.data() + used_, bytes_.data() + bytes_.size(), value);
    if (encoded.ec != std::errc{}) {
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

  std::optional<std::uint32_t> KeyEncoder::associatedText(const TerminalKey& key, const Encoding& encoding) {
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
    default:
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

  std::optional<char> KeyEncoder::controlByte(std::uint32_t codepoint) noexcept {
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

    const auto control = key.has(Modifier::control) ? controlByte(key.codepoint) : std::nullopt;
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

  KeyLabel::Text KeyLabel::chord(std::optional<KeyChord> prefix, KeyChord key, KeyLabelStyle style) {
    Text text;

    if (prefix) {
      append(text, *prefix, style);
      text.append(" ");
    }

    append(text, key, style);

    return text;
  }

  void KeyLabel::append(Text& text, KeyChord key, KeyLabelStyle style) {
    constexpr auto modifiers = std::to_array<ModifierLabel>({
        {.modifier = KeyChord::Modifier::control, .pc = "Ctrl+", .mac = "⌃"},
        {.modifier = KeyChord::Modifier::alt, .pc = "Alt+", .mac = "⌥"},
        {.modifier = KeyChord::Modifier::shift, .pc = "Shift+", .mac = "⇧"},
        {.modifier = KeyChord::Modifier::super, .pc = "Super+", .mac = "⌘"},
    });

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

    constexpr auto names = std::to_array<KeyName>({
        {.key = KeyChord::Key::up, .pc = "Up", .mac = "↑"},
        {.key = KeyChord::Key::down, .pc = "Down", .mac = "↓"},
        {.key = KeyChord::Key::left, .pc = "Left", .mac = "←"},
        {.key = KeyChord::Key::right, .pc = "Right", .mac = "→"},
        {.key = KeyChord::Key::home, .pc = "Home", .mac = "↖"},
        {.key = KeyChord::Key::end, .pc = "End", .mac = "↘"},
        {.key = KeyChord::Key::erase, .pc = "Del", .mac = "⌦"},
        {.key = KeyChord::Key::page_up, .pc = "PgUp", .mac = "⇞"},
        {.key = KeyChord::Key::page_down, .pc = "PgDn", .mac = "⇟"},
        {.key = KeyChord::Key::enter, .pc = "Enter", .mac = "↩"},
        {.key = KeyChord::Key::escape, .pc = "Esc", .mac = "esc"},
        {.key = KeyChord::Key::backspace, .pc = "Backspace", .mac = "⌫"},
        {.key = KeyChord::Key::tab, .pc = "Tab", .mac = "⇥"},
        {.key = KeyChord::Key::back_tab, .pc = "Shift+Tab", .mac = "⇧⇥"},
    });

    for (const auto& name : names) {
      if (name.key == key.key) {
        text.append(style == KeyLabelStyle::mac ? name.mac : name.pc);

        return;
      }
    }
  }

}
