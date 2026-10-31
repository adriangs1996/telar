#pragma once

#include "text/utf16_prefix.hpp"
#include <QByteArray>
#include <QChar>
#include <QString>
#include <cstddef>

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
