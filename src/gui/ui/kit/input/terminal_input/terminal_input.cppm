export module telar.gui.ui.kit.input.terminal_input;

import telar.gui.qt;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  QByteArray terminalKey(const QKeyEvent& event, const telar::InputModes& modes);
  bool controlModifier(Qt::KeyboardModifiers modifiers);
}
