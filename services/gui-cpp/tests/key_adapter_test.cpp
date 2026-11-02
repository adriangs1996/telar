#include "core/unicode_scalar.hpp"
#include "input/binding.hpp"
#include "input/key_encoder.hpp"
#include "input/terminal_key.hpp"
#include "platform/keyboard.hpp"
#include "qt/key_adapter.hpp"
#include "qt/key_encoding.hpp"
#include <QCoreApplication>
#include <QKeyEvent>
#include <QString>
#include <QtCore/qcoreevent.h>
#include <QtCore/qnamespace.h>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using Code = KeyChord::Key;
using Modifier = KeyChord::Modifier;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <platform::KeyboardConvention Convention>
void platformConventions() {
  using Adapter = KeyAdapter<Convention>;
  const QKeyEvent control{QEvent::KeyPress, Qt::Key_A, Adapter::control_modifier | Qt::ShiftModifier, QStringLiteral("\x01")};
  const auto normalized = Adapter::terminalKey(control);
  require(normalized && normalized->codepoint == 'a' && normalized->has(Modifier::control) && normalized->has(Modifier::shift) && !normalized->has(Modifier::super), "physical Control must normalize independently of Qt's Apple convention");
  const QKeyEvent command{QEvent::KeyPress, Qt::Key_A, Adapter::super_modifier, QStringLiteral("a")};
  const auto shortcut = Adapter::terminalKey(command);
  require(shortcut && shortcut->has(Modifier::super) && !shortcut->has(Modifier::control), "Command or Super must remain a GUI modifier");
  const QKeyEvent shifted{QEvent::KeyPress, Qt::Key_A, Qt::ShiftModifier, QStringLiteral("A")};
  const auto text = Adapter::terminalKey(shifted);
  require(text && text->codepoint == 'A' && !text->has(Modifier::shift), "native text must retain its Unicode while clearing consumed Shift");
  const QKeyEvent backwards{QEvent::KeyPress, Qt::Key_Backtab, Qt::ShiftModifier};
  require(Adapter::chord(backwards).key == Code::back_tab && Adapter::chord(backwards).modifiers == 0, "Shift+Tab must normalize to an unmodified back-tab");
  const QKeyEvent alt_backwards{QEvent::KeyPress, Qt::Key_Backtab, Qt::AltModifier | Qt::ShiftModifier};
  const auto alt_tab = Adapter::terminalKey(alt_backwards);
  KeyEncoder encoder;
  require(alt_tab && encoder.encode(*alt_tab, {}) == "\x1b\x1b[Z", "Alt+Shift+Tab must preserve both semantic modifiers");
}

void unicodeAndSyntheticInput() {
  constexpr auto flower = U'🌱';
  const QKeyEvent unicode{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QString::fromUcs4(&flower, 1)};
  const auto chord = NativeKeyAdapter::chord(unicode);
  require(NativeKeyAdapter::fromChord(chord).codepoint == flower, "non-BMP native input must round-trip through packed configuration chords");
  require(NativeKeyAdapter::fromChord({}).codepoint == 0, "synthetic NUL must remain a scalar instead of an empty string");
  KeyEncoder encoder;
  require(encoder.encode(NativeKeyAdapter::fromChord({}), {}) == std::string_view{"\0", 1}, "synthetic NUL must produce exactly one byte");
  const QKeyEvent composed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QStringLiteral("ab")};
  require(!NativeKeyAdapter::terminalKey(composed), "multi-scalar commits must not masquerade as a single physical key");
  const QKeyEvent malformed{QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, QString{QChar{static_cast<char16_t>(Utf8Scalar::first_surrogate)}}};
  require(!NativeKeyAdapter::terminalKey(malformed), "a lone UTF-16 surrogate must not enter the scalar encoder");
}

void fallbackInput() {
  const QKeyEvent function{QEvent::KeyPress, Qt::Key_F1, Qt::NoModifier};
  require(encodeKey(function, {}) == "\x1bOP", "existing function-key behavior must remain available");
  const QKeyEvent shortcut{QEvent::KeyPress, Qt::Key_F1, NativeKeyAdapter::super_modifier};
  require(encodeKey(shortcut, {}).isEmpty(), "fallback keys must also respect GUI shortcut ownership");
}

}

int main(int argc, char *argv[]) {
  const QCoreApplication application{argc, argv};

  try {
    platformConventions<platform::KeyboardConvention::standard>();
    platformConventions<platform::KeyboardConvention::apple>();
    unicodeAndSyntheticInput();
    fallbackInput();
    std::puts("gui-key-adapter: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-key-adapter: " << error.what() << '\n';

    return 1;
  }
}
