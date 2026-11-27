#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QKeyEvent>
#include <QStringView>
#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <utility>

#pragma once

import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.gui.foundation.system;
import telar.base.ds;

namespace telar::gui::qt {

  template <system::KeyboardConvention Convention>
  class KeyAdapter {
  public:
    static constexpr auto control_modifier = Convention == system::KeyboardConvention::apple ? Qt::MetaModifier : Qt::ControlModifier;
    static constexpr auto super_modifier = Convention == system::KeyboardConvention::apple ? Qt::ControlModifier : Qt::MetaModifier;
    static constexpr auto link_modifier = Convention == system::KeyboardConvention::apple ? super_modifier : control_modifier;

    [[nodiscard]] static unsigned modifiers(Qt::KeyboardModifiers native) noexcept {
      unsigned result = 0;

      for (const auto& [modifier, normalized] : {std::pair{control_modifier, Modifier::control}, std::pair{super_modifier, Modifier::super}, std::pair{Qt::AltModifier, Modifier::alt}, std::pair{Qt::ShiftModifier, Modifier::shift}}) {
        if (native.testFlag(modifier)) {
          result |= static_cast<unsigned>(normalized);
        }
      }

      return result;
    }

    [[nodiscard]] static KeyPhase phase(const QKeyEvent& event) noexcept {
      if (event.type() == QEvent::KeyRelease) {
        return KeyPhase::release;
      }

      return event.isAutoRepeat() ? KeyPhase::repeat : KeyPhase::press;
    }

    // On macOS Option is a layout's third level: Option+2 is `@` on a Spanish keyboard. A key
    // whose Option text is printable and not its own key types that text without Alt, unless
    // `option_as_alt` makes Option Meta: then it is Alt with the key under it.
    [[nodiscard]] static ds::Option<TerminalKey> terminalKey(const QKeyEvent& event, bool option_as_alt = false) {
      TerminalKey result{.modifiers = modifiers(event.modifiers()), .phase = phase(event)};
      const auto* const named = std::ranges::find(named_keys, event.key(), &decltype(named_keys)::value_type::first);
      if (named != named_keys.end()) {
        result.code = named->second;
        normalizeTab(result, event.key() == Qt::Key_Backtab);

        return result;
      }

      const auto modified = result.has(Modifier::control) || result.has(Modifier::super);
      const auto text = scalar(event.text());
      const auto ascii_key = event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde;
      if (ascii_key && (modified || event.text().isEmpty())) {
        result.codepoint = static_cast<std::uint32_t>(event.key());
      } else if (text) {
        result.codepoint = *text;
      } else {
        return {};
      }

      if (modified && result.codepoint >= 'A' && result.codepoint <= 'Z') {
        result.codepoint += 'a' - 'A';
      }

      if (!modified) {
        result.modifiers &= ~static_cast<unsigned>(Modifier::shift);
      }

      // Any key of a character, ñ or ç on a Spanish layout as much as an ASCII one: Option+ñ
      // types `~` there.
      if constexpr (Convention == system::KeyboardConvention::apple) {
        if (!modified && event.key() >= Qt::Key_Space && event.key() < first_special_key) {
          optionCharacter(result, event, text, option_as_alt);
        }
      }

      return result;
    }

    [[nodiscard]] static KeyChord chord(const QKeyEvent& event) {
      // Option can change the text without changing the shortcut's base key.
      if (event.modifiers().testFlag(Qt::AltModifier) && !event.modifiers().testFlag(Qt::GroupSwitchModifier) && event.key() >= Qt::Key_Space && event.key() <= Qt::Key_AsciiTilde) {
        auto character = static_cast<std::uint32_t>(event.key());
        auto flags = modifiers(event.modifiers());
        const auto modified = (flags & (static_cast<unsigned>(Modifier::control) | static_cast<unsigned>(Modifier::super))) != 0;
        if (character >= 'A' && character <= 'Z' && (modified || !event.modifiers().testFlag(Qt::ShiftModifier))) {
          character += 'a' - 'A';
        }

        if (!modified) {
          flags &= ~static_cast<unsigned>(Modifier::shift);
        }

        return {.character = KeyCharacter::pack(character), .modifiers = flags};
      }

      const auto key = terminalKey(event);
      if (!key) {
        return {.character = std::numeric_limits<std::uint32_t>::max(), .modifiers = modifiers(event.modifiers())};
      }

      KeyChord result{.key = key->code, .modifiers = key->modifiers};

      if (key->code == Code::character) {
        result.character = KeyCharacter::pack(key->codepoint);
      }

      return result;
    }

    [[nodiscard]] static TerminalKey fromChord(KeyChord chord) {
      TerminalKey result{.code = chord.key, .modifiers = chord.modifiers};

      if (chord.key == Code::character) {
        result.codepoint = KeyCharacter::codepoint(chord.character);
      }

      return result;
    }

  private:
    using Code = KeyChord::Key;
    using Modifier = KeyChord::Modifier;
    using NamedKey = std::pair<int, Code>;

    static constexpr auto named_keys = ds::Array{
        NamedKey{Qt::Key_Up, Code::up},
        NamedKey{Qt::Key_Down, Code::down},
        NamedKey{Qt::Key_Left, Code::left},
        NamedKey{Qt::Key_Right, Code::right},
        NamedKey{Qt::Key_Home, Code::home},
        NamedKey{Qt::Key_End, Code::end},
        NamedKey{Qt::Key_Delete, Code::erase},
        NamedKey{Qt::Key_PageUp, Code::page_up},
        NamedKey{Qt::Key_PageDown, Code::page_down},
        NamedKey{Qt::Key_Return, Code::enter},
        NamedKey{Qt::Key_Enter, Code::enter},
        NamedKey{Qt::Key_Escape, Code::escape},
        NamedKey{Qt::Key_Backspace, Code::backspace},
        NamedKey{Qt::Key_Tab, Code::tab},
        NamedKey{Qt::Key_Backtab, Code::tab},
    };

    static constexpr std::uint32_t first_printable = 0x20;
    static constexpr std::uint32_t delete_character = 0x7f;
    // Qt numbers a key of a character by its code point, and the keys of no character from here.
    static constexpr int first_special_key = 0x01000000;

    // An ASCII key typed with Option whose text is printable and not the key's own: that text
    // without Alt, or, when `option_as_alt` makes Option Meta, Alt with the key under it.
    static void optionCharacter(TerminalKey& result, const QKeyEvent& event, ds::Option<std::uint32_t> text, bool option_as_alt) noexcept {
      if (!result.has(Modifier::alt) || !text || *text < first_printable || *text == delete_character) {
        return;
      }

      const auto base = baseCharacter(event);
      if (*text == base) {
        return;
      }

      result.codepoint = option_as_alt ? base : *text;
      if (!option_as_alt) {
        result.modifiers &= ~static_cast<unsigned>(Modifier::alt);
      }
    }

    // The character of a key as typed without Option: lowercase unless Shift is held.
    static std::uint32_t baseCharacter(const QKeyEvent& event) noexcept {
      const auto character = static_cast<char32_t>(event.key());

      if (event.modifiers().testFlag(Qt::ShiftModifier)) {
        return character;
      }

      return QChar::toLower(character);
    }

    static void normalizeTab(TerminalKey& key, bool backwards) noexcept {
      if (key.code != Code::tab) {
        return;
      }

      if (backwards) {
        key.modifiers |= static_cast<unsigned>(Modifier::shift);
      }

      if (key.modifiers == static_cast<unsigned>(Modifier::shift)) {
        key.code = Code::back_tab;
        key.modifiers = 0;
      }
    }

    static ds::Option<std::uint32_t> scalar(QStringView text) noexcept {
      if (text.size() == 1 && !text.front().isSurrogate()) {
        return text.front().unicode();
      }

      if (text.size() == 2 && text.front().isHighSurrogate() && text.back().isLowSurrogate()) {
        return QChar::surrogateToUcs4(text.front(), text.back());
      }

      return {};
    }
  };

  using NativeKeyAdapter = KeyAdapter<system::keyboard_convention>;

}
