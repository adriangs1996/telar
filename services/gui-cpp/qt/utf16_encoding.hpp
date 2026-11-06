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
#include <QByteArray>
#include <QChar>
#include <QString>

#pragma once


import telar.gui.text.bounded_editor;

namespace telar::gui::qt {

// Supported Qt encoders differ in whether isolated UTF-16 surrogates emit bytes.
[[nodiscard]] inline Utf16Encoding utf16Encoding() {
  static const auto encoding = [] {
    const auto invalid = QString{QChar{Utf16Prefix::first_low_surrogate}}.toUtf8();

    return Utf16Encoding{.invalid_scalar_bytes = static_cast<std::size_t>(invalid.size())};
  }();

  return encoding;
}

}
