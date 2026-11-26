#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QColor>
#include <QObject>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

namespace telar::gui::qt {

  class ChromeStyle final : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(qreal smallRadius READ smallRadius CONSTANT)
    Q_PROPERTY(qreal controlRadius READ controlRadius CONSTANT)
    Q_PROPERTY(qreal surfaceRadius READ surfaceRadius CONSTANT)
    Q_PROPERTY(qreal dialogRadius READ dialogRadius CONSTANT)
    Q_PROPERTY(qreal hoverAlpha READ hoverAlpha CONSTANT)
    Q_PROPERTY(qreal selectionAlpha READ selectionAlpha CONSTANT)
    Q_PROPERTY(qreal outlineAlpha READ outlineAlpha CONSTANT)
    Q_PROPERTY(qreal focusAlpha READ focusAlpha CONSTANT)
    Q_PROPERTY(qreal wellAlpha READ wellAlpha CONSTANT)
    Q_PROPERTY(qreal menuRowPadding READ menuRowPadding CONSTANT)
    Q_PROPERTY(qreal menuRowVerticalPadding READ menuRowVerticalPadding CONSTANT)
    Q_PROPERTY(qreal menuMark READ menuMark CONSTANT)
    Q_PROPERTY(qreal menuGap READ menuGap CONSTANT)

  public:
    explicit ChromeStyle(QObject* parent = nullptr)
        : QObject(parent) {}

    [[nodiscard]] qreal smallRadius() const noexcept {
      return gui::ChromeStyle::small_radius;
    }

    [[nodiscard]] qreal controlRadius() const noexcept {
      return gui::ChromeStyle::control_radius;
    }

    [[nodiscard]] qreal surfaceRadius() const noexcept {
      return gui::ChromeStyle::surface_radius;
    }

    [[nodiscard]] qreal dialogRadius() const noexcept {
      return gui::ChromeStyle::dialog_radius;
    }

    [[nodiscard]] qreal hoverAlpha() const noexcept {
      return gui::ChromeStyle::hover_alpha;
    }

    [[nodiscard]] qreal selectionAlpha() const noexcept {
      return gui::ChromeStyle::selection_alpha;
    }

    [[nodiscard]] qreal outlineAlpha() const noexcept {
      return gui::ChromeStyle::outline_alpha;
    }

    [[nodiscard]] qreal focusAlpha() const noexcept {
      return gui::ChromeStyle::focus_alpha;
    }

    [[nodiscard]] qreal wellAlpha() const noexcept {
      return gui::ChromeStyle::well_alpha;
    }

    [[nodiscard]] qreal menuRowPadding() const noexcept {
      return gui::ChromeStyle::menu_row_padding;
    }

    [[nodiscard]] qreal menuRowVerticalPadding() const noexcept {
      return gui::ChromeStyle::menu_row_vertical_padding;
    }

    [[nodiscard]] qreal menuMark() const noexcept {
      return gui::ChromeStyle::menu_mark;
    }

    [[nodiscard]] qreal menuGap() const noexcept {
      return gui::ChromeStyle::menu_gap;
    }

    // `ink` moved the least it must to read at `ratio` on the opaque `ground`; the chrome's
    // secondary text and the marks' letters ask it, so every theme keeps them readable.
    Q_INVOKABLE [[nodiscard]] QColor legible(const QColor& ink, const QColor& ground, qreal ratio) const noexcept {
      const auto color = [](const QColor& source) {
        return gui::Color{.r = source.redF(), .g = source.greenF(), .b = source.blueF(), .a = source.alphaF()};
      };
      const auto result = gui::legible(color(ink), color(ground), static_cast<float>(ratio));

      return QColor::fromRgbF(result.r, result.g, result.b, result.a);
    }

    // The height of a line of chrome text at `pixelSize`, the one the machine rows are laid out
    // with, so a menu drawn in QML stacks its lines as they do.
    Q_INVOKABLE [[nodiscard]] qreal lineHeight(qreal pixelSize) const noexcept {
      return static_cast<qreal>(gui::ChromeMetrics::lineHeight(static_cast<std::uint16_t>(std::lround(pixelSize))));
    }
  };

}
