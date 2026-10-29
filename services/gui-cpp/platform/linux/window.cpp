#include "platform/window.hpp"
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QWindow>
#include <QtCore/qtenvironmentvariables.h>

namespace telar::gui::platform {

void configureGraphics() {
  if (!qEnvironmentVariableIsSet("QSG_RHI_BACKEND") && !qEnvironmentVariableIsSet("QT_QUICK_BACKEND")) {
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
  }
}

bool defaultTitlebar() noexcept {
  return true;
}

bool usesCommandKey() noexcept {
  return false;
}

float windowControls(const QWindow &) noexcept {
  return 0;
}

void configureWindow(QWindow &window, WindowAppearance appearance) {
  window.setFlag(Qt::FramelessWindowHint, !appearance.titlebar);
}

}
