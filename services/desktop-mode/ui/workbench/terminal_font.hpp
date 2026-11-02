#pragma once

#include <QFont>
#include <QSizeF>
#include <QVariantMap>
#include <array>
#include <cstddef>

namespace workbench {
struct TerminalFont {
  static constexpr std::size_t face_count = 4;
  std::array<QFont, face_count> faces;
  QSizeF cell;
  qreal baseline = 0;
  bool fixed_pitch = true;

  static TerminalFont resolve(const QVariantMap &settings, qreal scale);
  static void validate(const QVariantMap &settings);
  static TerminalFont fromFont(QFont base, QSizeF cell, qreal baseline);
};
}
