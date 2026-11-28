#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QKeyEvent>

#pragma once

import telar.wire.vocabulary;

namespace telar::gui::qt {
  QByteArray terminalKey(const QKeyEvent& event, const telar::InputModes& modes);
  bool controlModifier(Qt::KeyboardModifiers modifiers);
}
