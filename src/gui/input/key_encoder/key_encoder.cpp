module telar.gui.input.key_encoder;

import std;

import telar.base.text;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;

namespace telar::gui {

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
