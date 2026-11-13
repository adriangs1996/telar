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
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <span>
#include <tuple>
#include <charconv>
#include <limits>
#include <system_error>
#include <utility>
#include "key_adapter.hpp"
#include "terminal_input.hpp"
#include <QByteArray>
#include <QKeyEvent>

#pragma once


import telar.gui.input.key_encoder;

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

  return terminalKey(event, modes);
}

}
