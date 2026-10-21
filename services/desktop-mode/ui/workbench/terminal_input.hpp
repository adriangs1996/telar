#pragma once

#include "terminal_screen.hpp"
#include <QKeyEvent>

namespace workbench {
  QByteArray terminalKey(const QKeyEvent &event, const telar::InputModes &modes);
  QByteArray terminalPaste(const QString &text, const telar::InputModes &modes);
  bool controlModifier(Qt::KeyboardModifiers modifiers);
} // namespace workbench
