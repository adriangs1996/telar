#pragma once

#include <QFont>
#include <QSizeF>
#include <QVariantMap>
#include <array>

namespace workbench {
  // The terminal's faces and cell from the theme's `terminal.font`, with the GUI's metrics: the
  // size rounds to physical pixels, the cell to whole physical pixels, and extra line height is
  // split above and below the baseline.
  struct TerminalFont {
    std::array<QFont, 4> faces;
    QSizeF cell;
    qreal baseline = 0;
    bool fixed_pitch = true;

    // Throws when the family or style is not installed, or the spacing leaves no cell.
    static TerminalFont resolve(const QVariantMap &settings, qreal scale);
    // Rejects settings resolve would throw on, before a theme takes effect.
    static void validate(const QVariantMap &settings);
  };
} // namespace workbench
