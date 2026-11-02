#include "platform/window.hpp"
#include "background_effect.hpp"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QLatin1StringView>
#include <QObject>
#include <QPlatformSurfaceEvent>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QString>
#include <QSurface>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qtenvironmentvariables.h>
#include <memory>

namespace telar::gui::platform {

namespace {

class WaylandSurfaceLifetime final : public QObject {
public:
  explicit WaylandSurfaceLifetime(QWindow &window)
      : QObject(&window) {
    connect(&window, &QWindow::visibleChanged, this, [&window](bool visible) {
      if (visible || window.surfaceType() != QSurface::VulkanSurface) {
        return;
      }

      auto *quick = qobject_cast<QQuickWindow *>(&window);
      if (quick == nullptr) {
        return;
      }

      // Wayland invalidates VkSurfaceKHR before QWindow delivers its surface event.
      // Let the render loop release the swapchain while that surface is still alive.
      QPlatformSurfaceEvent about_to_destroy{QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed};
      QCoreApplication::sendEvent(quick, &about_to_destroy);
    });
  }
};

WaylandSurfaceLifetime &surfaceLifetime(QWindow &window) {
  for (auto *child : window.children()) {
    if (auto *observer = dynamic_cast<WaylandSurfaceLifetime *>(child)) {
      return *observer;
    }
  }

  return *std::make_unique<WaylandSurfaceLifetime>(window).release();
}

}

void configureKeyRepeat() {}

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

float windowControls(const QWindow &window) noexcept {
  static_cast<void>(window);

  return 0;
}

void configureWindow(QWindow &window, WindowAppearance appearance) {
  if (QGuiApplication::platformName().startsWith(QLatin1StringView{"wayland"}) && qobject_cast<QQuickWindow *>(&window) != nullptr) {
    static_cast<void>(surfaceLifetime(window));
  }

  window.setFlag(Qt::FramelessWindowHint, !appearance.titlebar);
  if (QGuiApplication::platformName().startsWith(QLatin1StringView{"wayland"})) {
    configureBackgroundEffect(window, appearance);
  }
}

}
