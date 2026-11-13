#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <QObject>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.presentation.history_inspection_geometry;

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

  public:
    explicit ChromeStyle(QObject *parent = nullptr)
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
  };

}
