#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/input/key_adapter.hpp"
#include "ui/foundation/input/key_encoding.hpp"
#include <QCoreApplication>
#include <QKeyEvent>
#include <QString>
#include <QtCore/qcoreevent.h>
#include <QtCore/qnamespace.h>
#include <array>
#include <cstddef>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>

import telar.testing;
import telar.gui.foundation.core;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;
  using namespace telar::gui::qt;
  using Code = KeyChord::Key;
  using Modifier = KeyChord::Modifier;

  template <system::KeyboardConvention Convention>
  void platformConventions() {
    using Adapter = KeyAdapter<Convention>;
    const QKeyEvent control{QEvent::KeyPress, Qt::Key_A, Adapter::control_modifier | Qt::ShiftModifier, QStringLiteral("\x01")};
    const auto normalized = Adapter::terminalKey(control);

    check(normalized && normalized->codepoint == 'a' && normalized->has(Modifier::control) && normalized->has(Modifier::shift) && !normalized->has(Modifier::super), "physical Control must normalize independently of Qt's Apple convention");
    const QKeyEvent command{QEvent::KeyPress, Qt::Key_A, Adapter::super_modifier, QStringLiteral("a")};
    const auto shortcut = Adapter::terminalKey(command);

    check(shortcut && shortcut->has(Modifier::super) && !shortcut->has(Modifier::control), "Command or Super must remain a GUI modifier");
    const QKeyEvent shifted{QEvent::KeyPress, Qt::Key_A, Qt::ShiftModifier, QStringLiteral("A")};
    const auto text = Adapter::terminalKey(shifted);

    check(text && text->codepoint == 'A' && !text->has(Modifier::shift), "native text must retain its Unicode while clearing consumed Shift");
    const QKeyEvent backwards{QEvent::KeyPress, Qt::Key_Backtab, Qt::ShiftModifier};

    check(Adapter::chord(backwards).key == Code::back_tab && Adapter::chord(backwards).modifiers == 0, "Shift+Tab must normalize to an unmodified back-tab");
    const QKeyEvent alt_backwards{QEvent::KeyPress, Qt::Key_Backtab, Qt::AltModifier | Qt::ShiftModifier};
    const auto alt_tab = Adapter::terminalKey(alt_backwards);
    KeyEncoder encoder;

    check(alt_tab && encoder.encode(*alt_tab, {}) == "\x1b\x1b[Z", "Alt+Shift+Tab must preserve both semantic modifiers");
  }

  template <system::KeyboardConvention Convention>
  void altShortcutsUseTheKeyWithoutChangingTerminalText() {
    using Adapter = KeyAdapter<Convention>;

    struct Case {
      int key{};
      QString text;
      char character{};
    };

    const telar::ds::Array cases{
        Case{Qt::Key_H, QStringLiteral("˙"), 'h'},
        Case{Qt::Key_J, QStringLiteral("∆"), 'j'},
        Case{Qt::Key_K, QStringLiteral("˚"), 'k'},
        Case{Qt::Key_L, QStringLiteral("¬"), 'l'},
        Case{Qt::Key_N, QStringLiteral("˜"), 'n'},
        Case{Qt::Key_M, QStringLiteral("µ"), 'm'},
        Case{Qt::Key_N, QString{}, 'n'},
        Case{Qt::Key_1, QStringLiteral("¡"), '1'},
    };

    for (const auto& entry : cases) {
      for (const auto phase : {KeyPhase::press, KeyPhase::repeat, KeyPhase::release}) {
        const QKeyEvent event{phase == KeyPhase::release ? QEvent::KeyRelease : QEvent::KeyPress, entry.key, Qt::AltModifier, entry.text, phase == KeyPhase::repeat};
        const auto chord = Adapter::chord(event);

        check(chord.key == Code::character && chord.character == static_cast<unsigned>(entry.character) && chord.modifiers == static_cast<unsigned>(Modifier::alt), "Alt shortcuts must match their base key on press, repeat and release, including dead-key input");
        if (!entry.text.isEmpty()) {
          const auto text = Adapter::terminalKey(event);

          check(text && text->codepoint == static_cast<unsigned>(entry.text.front().unicode()), "binding recognition must preserve the original Option text for terminal input");
          if (phase == KeyPhase::press) {
            KeyEncoder encoder;
            const auto expected = QByteArray{"\x1b"} + entry.text.toUtf8();

            check(encoder.encode(*text, {}) == std::string_view{expected.constData(), static_cast<std::size_t>(expected.size())}, "unbound Alt input must keep its existing terminal encoding");
          }
        }
      }

      const QKeyEvent shortcut{QEvent::ShortcutOverride, entry.key, Qt::AltModifier, entry.text};

      check(Adapter::chord(shortcut).character == static_cast<unsigned>(entry.character), "Alt shortcuts must also be recognized before native text composition");
    }

    const QKeyEvent shifted{QEvent::KeyPress, Qt::Key_N, Qt::AltModifier | Qt::ShiftModifier, QStringLiteral("˜")};
    const auto upper = Adapter::chord(shifted);

    check(upper.character == 'N' && upper.modifiers == static_cast<unsigned>(Modifier::alt), "Alt+Shift must use the uppercase chord representation expected by configuration");
    const QKeyEvent altgr{QEvent::KeyPress, Qt::Key_Q, Qt::AltModifier | Qt::GroupSwitchModifier, QStringLiteral("@")};

    check(Adapter::chord(altgr).character == '@', "AltGr text must not be replaced with an Alt shortcut's base key");
    for (const auto extra : {Adapter::control_modifier, Adapter::super_modifier}) {
      const QKeyEvent combined{QEvent::KeyPress, Qt::Key_H, Qt::AltModifier | extra, QStringLiteral("˙")};
      const auto chord = Adapter::chord(combined);

      check(chord.character == 'h' && chord.modifiers == Adapter::modifiers(combined.modifiers()), "Alt combined with Control or Super must retain both shortcut modifiers");
    }

    const QKeyEvent unicode{QEvent::KeyPress, Qt::Key_unknown, Qt::AltModifier, QStringLiteral("ñ")};

    check(Adapter::fromChord(Adapter::chord(unicode)).codepoint == U'ñ', "keys without an ASCII base must retain their Unicode shortcut representation");
  }

  void unicodeAndSyntheticInput() {
    constexpr auto flower = U'🌱';
    const QKeyEvent unicode{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QString::fromUcs4(&flower, 1)};
    const auto chord = NativeKeyAdapter::chord(unicode);

    check(NativeKeyAdapter::fromChord(chord).codepoint == flower, "non-BMP native input must round-trip through packed configuration chords");
    check(NativeKeyAdapter::fromChord({}).codepoint == 0, "synthetic NUL must remain a scalar instead of an empty string");
    KeyEncoder encoder;

    check(encoder.encode(NativeKeyAdapter::fromChord({}), {}) == std::string_view{"\0", 1}, "synthetic NUL must produce exactly one byte");
    const QKeyEvent composed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QStringLiteral("ab")};

    check(!NativeKeyAdapter::terminalKey(composed), "multi-scalar commits must not masquerade as a single physical key");
    const QKeyEvent malformed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QString{QChar{static_cast<char16_t>(Utf8Scalar::first_surrogate)}}};

    check(!NativeKeyAdapter::terminalKey(malformed), "a lone UTF-16 surrogate must not enter the scalar encoder");
  }

  void fallbackInput() {
    const QKeyEvent function{QEvent::KeyPress, Qt::Key_F1, Qt::NoModifier};

    check(encodeKey(function, {}) == "\x1bOP", "existing function-key behavior must remain available");
    const QKeyEvent shortcut{QEvent::KeyPress, Qt::Key_F1, NativeKeyAdapter::super_modifier};

    check(encodeKey(shortcut, {}).isEmpty(), "fallback keys must also respect GUI shortcut ownership");
  }

  const telar::testing::Case case_platform_conventions_standard{"key_adapter.platform_conventions_standard", platformConventions<system::KeyboardConvention::standard>};
  const telar::testing::Case case_platform_conventions_apple{"key_adapter.platform_conventions_apple", platformConventions<system::KeyboardConvention::apple>};
  const telar::testing::Case case_alt_shortcuts_standard{"key_adapter.alt_shortcuts_use_the_key_without_changing_terminal_text_standard", altShortcutsUseTheKeyWithoutChangingTerminalText<system::KeyboardConvention::standard>};
  const telar::testing::Case case_alt_shortcuts_apple{"key_adapter.alt_shortcuts_use_the_key_without_changing_terminal_text_apple", altShortcutsUseTheKeyWithoutChangingTerminalText<system::KeyboardConvention::apple>};
  const telar::testing::Case case_unicode_and_synthetic_input{"key_adapter.unicode_and_synthetic_input", unicodeAndSyntheticInput};
  const telar::testing::Case case_fallback_input{"key_adapter.fallback_input", fallbackInput};

}
