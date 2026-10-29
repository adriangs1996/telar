#include "window_activation.hpp"
#include <QWindow>

namespace telar::gui::test {

void activateApplication() {
}

void configureComponentWindow(QWindow &) {
}

void activateWindow(QWindow &window) {
  window.requestActivate();
}

}
