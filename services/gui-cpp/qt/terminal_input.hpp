#pragma once

#include "telar_client/serializers/telar_frame.hpp"
#include <QKeyEvent>

namespace telar::gui::qt {
QByteArray terminalKey(const QKeyEvent &event, const telar::InputModes &modes);
QByteArray terminalPaste(const QString &text, const telar::InputModes &modes);
bool controlModifier(Qt::KeyboardModifiers modifiers);
}
