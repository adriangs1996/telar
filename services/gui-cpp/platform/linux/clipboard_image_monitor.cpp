#include "platform/clipboard_image_monitor.hpp"
#include "application/dependencies.hpp"
#include "platform/clipboard_image_source.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QtCore/qtconfigmacros.h>
#include <QtGui/qguiapplication_platform.h>

namespace telar::gui::platform {

namespace {

::wl_display *waylandDisplay() noexcept {
#if QT_CONFIG(wayland)
  if (const auto *native = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>()) {
    return native->display();
  }
#endif

  return nullptr;
}

}

ClipboardImageMonitor::ClipboardImageMonitor(ApplicationAllocator &memory)
    : memory_(memory),
      native_(memory, waylandDisplay()) {
#if QT_CONFIG(xcb)
  if (qGuiApp->nativeInterface<QNativeInterface::QX11Application>() != nullptr) {
    xcb_.emplace(memory_);
  }
#endif

}

ClipboardImageMonitor::~ClipboardImageMonitor() = default;

void ClipboardImageMonitor::cancel() noexcept {
  if (xcb_) {
    xcb_->cancel();
  }
}

ClipboardImageSource ClipboardImageMonitor::snapshot() {
  const auto *const board = QGuiApplication::clipboard();
  if (xcb_ && board != nullptr && !board->ownsClipboard()) {
    return xcb_->capture();
  }

  if (native_.available() && board != nullptr && !board->ownsClipboard()) {
    return ClipboardImageSource::fromPipe(memory_, native_.capture());
  }

  return ClipboardImageSource::snapshot(memory_);
}

}
