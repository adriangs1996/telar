#include "../../ui/workbench/native.hpp"
#include <QWindow>

namespace workbench::native {
  QRect frame(QWindow &window) {
    return window.geometry();
  }

  void setFrame(QWindow &window, QRect frame) {
    window.setGeometry(frame);
  }

  void raise(QWindow &window) {
    window.raise();
  }

  void setVisible(QWindow &window, bool visible) {
    window.setOpacity(visible ? 1 : 0);
  }
} // namespace workbench::native
