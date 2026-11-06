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
#include <QKeyEvent>
#include <QStringView>
#include <limits>
#include <utility>

#pragma once


import telar.gui.input.key_encoder;
import telar.gui.platform.private_file_stamp;

namespace telar::gui::qt {

template <platform::KeyboardConvention Convention>
class KeyAdapter {
public:
  static constexpr auto control_modifier = Convention == platform::KeyboardConvention::apple ? Qt::MetaModifier : Qt::ControlModifier;
  static constexpr auto super_modifier = Convention == platform::KeyboardConvention::apple ? Qt::ControlModifier : Qt::MetaModifier;
  static constexpr auto link_modifier = Convention == platform::KeyboardConvention::apple ? super_modifier : control_modifier;

  [[nodiscard]] static unsigned modifiers(Qt::KeyboardModifiers native) noexcept {
    unsigned result = 0;
    for (const auto &[modifier, normalized] : {std::pair{control_modifier, Modifier::control}, std::pair{super_modifier, Modifier::super}, std::pair{Qt::AltModifier, Modifier::alt}, std::pair{Qt::ShiftModifier, Modifier::shift}}) {
      if (native.testFlag(modifier)) {
        result |= static_cast<unsigned>(normalized);
      }
    }

    return result;
  }

  [[nodiscard]] static KeyPhase phase(const QKeyEvent &event) noexcept {
    if (event.type() == QEvent::KeyRelease) {
      return KeyPhase::release;
    }

    return event.isAutoRepeat() ? KeyPhase::repeat : KeyPhase::press;
  }

  [[nodiscard]] static std::optional<TerminalKey> terminalKey(const QKeyEvent &event) {
    TerminalKey result{.modifiers = modifiers(event.modifiers()), .phase = phase(event)};
    const auto *const named = std::ranges::find(named_keys, event.key(), &decltype(named_keys)::value_type::first);
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

    return result;
  }

  [[nodiscard]] static KeyChord chord(const QKeyEvent &event) {
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

  static constexpr auto named_keys = std::to_array<std::pair<int, Code>>({
      {Qt::Key_Up, Code::up},
      {Qt::Key_Down, Code::down},
      {Qt::Key_Left, Code::left},
      {Qt::Key_Right, Code::right},
      {Qt::Key_Home, Code::home},
      {Qt::Key_End, Code::end},
      {Qt::Key_Delete, Code::erase},
      {Qt::Key_PageUp, Code::page_up},
      {Qt::Key_PageDown, Code::page_down},
      {Qt::Key_Return, Code::enter},
      {Qt::Key_Enter, Code::enter},
      {Qt::Key_Escape, Code::escape},
      {Qt::Key_Backspace, Code::backspace},
      {Qt::Key_Tab, Code::tab},
      {Qt::Key_Backtab, Code::tab},
  });

  static void normalizeTab(TerminalKey &key, bool backwards) noexcept {
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

  static std::optional<std::uint32_t> scalar(QStringView text) noexcept {
    if (text.size() == 1 && !text.front().isSurrogate()) {
      return text.front().unicode();
    }

    if (text.size() == 2 && text.front().isHighSurrogate() && text.back().isLowSurrogate()) {
      return QChar::surrogateToUcs4(text.front(), text.back());
    }

    return {};
  }
};

using NativeKeyAdapter = KeyAdapter<platform::keyboard_convention>;

}
