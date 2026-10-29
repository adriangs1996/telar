#include "terminal_font.hpp"
#include "../bundled_fonts.hpp"
#include <QFont>
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QScreen>
#include <QVariantMap>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <stdexcept>

namespace workbench {
TerminalFont TerminalFont::resolve(const QVariantMap &settings, qreal scale) {
  const auto family = settings.value("family").toString();
  const auto style = settings.value("style").toString();
  auto families = ui::bundledFonts();

  if (!family.isEmpty()) {
    if (!QFontDatabase::hasFamily(family)) {
      throw std::runtime_error("Terminal font family not found: " + family.toStdString());
    }

    families.prepend(family);
  }

  QFont base = QFontDatabase::systemFont(QFontDatabase::FixedFont);
  base.setFamilies(families);

  if (!style.isEmpty()) {
    const auto styles = QFontDatabase::styles(QFontInfo(base).family());
    const auto found = std::ranges::find_if(styles, [&style](const QString &candidate) {
      return candidate.compare(style, Qt::CaseInsensitive) == 0;
    });

    if (found == styles.end()) {
      throw std::runtime_error("Terminal font style not found: " + style.toStdString());
    }

    base.setStyleName(*found);
  }

  constexpr qreal points_per_inch = 72;
  const auto *screen = QGuiApplication::primaryScreen();
  const auto dpi = screen != nullptr ? screen->logicalDotsPerInchY() : points_per_inch;
  constexpr qreal default_size = 15;
  const auto size = settings.value("size", default_size).toDouble();
  const auto line_height = settings.value("line_height", 1).toDouble();
  const auto letter_spacing = settings.value("letter_spacing", 0).toDouble();
  base.setPointSizeF(std::round(size * scale) / scale * points_per_inch / dpi);

  const QFontMetricsF metrics(base);
  const auto natural = (metrics.ascent() + metrics.descent()) * scale;
  const auto height = std::max(1.0, std::round(natural * line_height));
  const auto width =
      std::round((metrics.horizontalAdvance(QLatin1Char('M')) + letter_spacing) * scale);

  if (width <= 0) {
    throw std::runtime_error("Terminal font letter_spacing produces a nonpositive cell width");
  }

  const auto baseline = std::round((metrics.ascent() * scale) + ((height - natural) / 2)) / scale;

  return fromFont(base, {width / scale, height / scale}, baseline);
}

TerminalFont TerminalFont::fromFont(QFont base, QSizeF cell, qreal baseline) {
  base.setKerning(false);
  base.setFeature("liga", 1);
  base.setFeature("clig", 1);
  base.setFeature("calt", 1);
  base.setStyleHint(QFont::Monospace);

  TerminalFont result;
  result.cell = cell;
  result.baseline = baseline;

  for (std::size_t index = 0; index < result.faces.size(); ++index) {
    auto variant = base;

    if (index != 0) {
      constexpr std::size_t bold_mask = 1;
      constexpr std::size_t italic_mask = 2;
      variant.setBold((index & bold_mask) != 0 || base.bold());
      variant.setItalic((index & italic_mask) != 0 || base.italic());
    }

    const auto advance = QFontMetricsF(variant).horizontalAdvance(QLatin1Char('M'));
    variant.setLetterSpacing(QFont::AbsoluteSpacing, result.cell.width() - advance);
    result.faces[index] = variant;
  }

  result.fixed_pitch = QFontInfo(base).fixedPitch();

  return result;
}

void TerminalFont::validate(const QVariantMap &settings) {
  resolve(settings, 1);
}
}
