#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QFont>
#include <QSizeF>
#include <QVariantMap>
#include <array>
#include <cstddef>

#pragma once

import telar.base.ds;

namespace telar::gui::qt {
  struct TerminalFont {
    static constexpr std::size_t face_count = 4;
    ds::Array<QFont, face_count> faces;
    QSizeF cell;
    qreal baseline = 0;
    bool fixed_pitch = true;

    static TerminalFont resolve(const QVariantMap& settings, qreal scale);
    static void validate(const QVariantMap& settings);
    static TerminalFont fromFont(QFont base, QSizeF cell, qreal baseline);
  };
}
