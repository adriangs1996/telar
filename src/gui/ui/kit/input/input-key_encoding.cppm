export module telar.gui.ui.kit.input:key_encoding;

import std;
import telar.gui.qt;
import :key_adapter;
import telar.gui.ui.kit.input.terminal_input;
import telar.gui.foundation.keys;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline QByteArray encodeKey(const TerminalKey& key, const InputModes& modes) {
    KeyEncoder encoder;
    const auto bytes = encoder.encode(key, modes);

    return {bytes.data(), static_cast<qsizetype>(bytes.size())};
  }

  [[tbc::hot_path]] inline QByteArray encodeKey(const QKeyEvent& event, const InputModes& modes) {
    if (const auto semantic = NativeKeyAdapter::terminalKey(event)) {
      return encodeKey(*semantic, modes);
    }

    if (event.modifiers().testFlag(NativeKeyAdapter::super_modifier)) {
      return {};
    }

    return terminalKey(event, modes);
  }

}
