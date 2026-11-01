#include "window_activation.hpp"
#include <QWindow>

namespace telar::gui::test {

void activateApplication() {
}

void configureComponentWindow(QWindow & /*unused*/) {
}

void activateWindow(QWindow &window) {
  window.requestActivate();
}

bool windowManagerReady([[maybe_unused]] const QWindow &window) {
  return true;
}

}
