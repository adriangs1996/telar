#pragma once

#include "input/key_encoder.hpp"
#include "input/terminal_key.hpp"
#include "key_adapter.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/workbench/terminal_input.hpp"
#include <QByteArray>
#include <QKeyEvent>

namespace telar::gui::qt {

inline QByteArray encodeKey(const TerminalKey &key, const InputModes &modes) {
  KeyEncoder encoder;
  const auto bytes = encoder.encode(key, modes);

  return {bytes.data(), static_cast<qsizetype>(bytes.size())};
}

inline QByteArray encodeKey(const QKeyEvent &event, const InputModes &modes) {
  if (const auto semantic = NativeKeyAdapter::terminalKey(event)) {
    return encodeKey(*semantic, modes);
  }

  if (event.modifiers().testFlag(NativeKeyAdapter::super_modifier)) {
    return {};
  }

  return workbench::terminalKey(event, modes);
}

}
