#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../window.hpp"
#include <QCoreApplication>
#include <QGuiApplication>
#include <QLatin1StringView>
#include <QObject>
#include <QPlatformSurfaceEvent>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QString>
#include <QSurface>
#include <QVersionNumber>
#include <QVulkanFunctions>
#include <QVulkanInstance>
#include <QWindow>
#include <QtCore/qnamespace.h>
#include <QtCore/qtenvironmentvariables.h>
#include <cstdint>
#include <memory>

#include "platform/window.hpp"


import telar.gui.platform.private_file_stamp;

namespace telar::gui::platform {

bool supportsImmediateWindowUpdates() {
  return false;
}

void deliverPendingWindowUpdate(QWindow &) {}

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

// Qt Quick aborts when the API it was told to use cannot start, and many
// desktops, virtual machines among them, have a Vulkan loader but no device.
bool vulkanDeviceAvailable() {
  // The loader rejects an instance that names no API version.
  const QVersionNumber vulkan_baseline{1, 0};
  QVulkanInstance probe;
  probe.setApiVersion(vulkan_baseline);
  if (!probe.create()) {
    return false;
  }

  std::uint32_t devices = 0;
  probe.functions()->vkEnumeratePhysicalDevices(probe.vkInstance(), &devices, nullptr);

  return devices > 0;
}

}

void configureKeyRepeat() {}

void configureGraphics() {
  if (qEnvironmentVariableIsSet("QSG_RHI_BACKEND") || qEnvironmentVariableIsSet("QT_QUICK_BACKEND")) {
    return;
  }

  QQuickWindow::setGraphicsApi(vulkanDeviceAvailable() ? QSGRendererInterface::Vulkan : QSGRendererInterface::OpenGL);
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
