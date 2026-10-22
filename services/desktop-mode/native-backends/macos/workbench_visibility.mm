#include "../../ui/workbench/native.hpp"
#include <QGuiApplication>
#include <QScreen>
#include <QWindow>

namespace workbench::native {
  QRect frame(QWindow &window) {
    return window.geometry();
  }

  namespace {
    constexpr double park_sliver = 1;

    // Where a window waits while its tab is not shown: past the bottom corner of its display,
    // leaving a sliver on screen. Of the two bottom corners, the one with less of another display
    // beyond it, or the parked window would show there.
    QPointF parkPosition(const QRectF &frame) {
      const auto *home = QGuiApplication::screenAt(frame.center().toPoint());
      if (!home) {
        home = QGuiApplication::primaryScreen();
      }

      const QRectF bounds = home->geometry();
      const QPointF right(bounds.right() - park_sliver, bounds.bottom() - park_sliver);
      const QPointF left(bounds.left() - frame.width() + park_sliver,
                         bounds.bottom() - park_sliver);
      const auto spill = [&](QPointF origin) {
        double area = 0;
        for (const auto *screen : QGuiApplication::screens()) {
          const auto shared = QRectF(origin, frame.size()).intersected(QRectF(screen->geometry()));
          area += screen == home ? 0 : shared.width() * shared.height();
        }

        return area;
      };

      return spill(left) < spill(right) ? left : right;
    }

  } // namespace

  void setFrame(QWindow &window, QRect frame) {
    window.setGeometry(frame);
  }

  void raise(QWindow &window) {
    window.raise();
  }

  void setVisible(QWindow &window, bool visible) {
    window.setOpacity(visible ? 1 : 0);
  }

  void WindowObserver::hide(std::uint32_t window, QRectF frame) {
    move(window, parkPosition(frame));
  }
} // namespace workbench::native
