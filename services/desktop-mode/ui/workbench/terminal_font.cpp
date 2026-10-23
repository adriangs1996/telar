#include "terminal_font.hpp"
#include "../bundled_fonts.hpp"
#include <QFontDatabase>
#include <QFontInfo>
#include <QFontMetricsF>
#include <QGuiApplication>
#include <QScreen>
#include <algorithm>
#include <cmath>
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
    const auto dpi = screen ? screen->logicalDotsPerInchY() : points_per_inch;
    const auto size = settings.value("size", 15).toDouble();
    const auto line_height = settings.value("line_height", 1).toDouble();
    const auto letter_spacing = settings.value("letter_spacing", 0).toDouble();
    base.setPointSizeF(std::round(size * scale) / scale * points_per_inch / dpi);
    base.setKerning(false);
    // Explicit features keep programming ligatures when spacing rounds the face onto the grid.
    base.setFeature("liga", 1);
    base.setFeature("clig", 1);
    base.setFeature("calt", 1);
    base.setStyleHint(QFont::Monospace);

    const QFontMetricsF metrics(base);
    const auto natural = (metrics.ascent() + metrics.descent()) * scale;
    const auto height = std::max(1.0, std::round(natural * line_height));
    const auto width =
        std::round((metrics.horizontalAdvance(QLatin1Char('M')) + letter_spacing) * scale);

    if (width <= 0) {
      throw std::runtime_error("Terminal font letter_spacing produces a nonpositive cell width");
    }

    TerminalFont result;
    result.cell = {width / scale, height / scale};
    result.baseline = std::round(metrics.ascent() * scale + (height - natural) / 2) / scale;

    for (std::size_t index = 0; index < result.faces.size(); ++index) {
      auto variant = base;

      if (index != 0) {
        // Keep the selected named instance; Qt synthesizes the terminal's bold and italic.
        variant.setBold((index & 1) || base.bold());
        variant.setItalic((index & 2) || base.italic());
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
} // namespace workbench
