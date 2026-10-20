#include "quick_surface.hpp"
#include <QColor>
#include <QCoreApplication>
#include <QDebug>
#include <QQmlComponent>
#include <QQmlError>
#include <QSurfaceFormat>
#include <memory>
#include <stdexcept>

QuickSurface::QuickSurface() {
  auto format = window_.requestedFormat();
  format.setAlphaBufferSize(8);
  window_.setFormat(format);
  window_.setColor(Qt::transparent);
}

QQuickWindow &QuickSurface::window() noexcept {
  return window_;
}

QQmlEngine &QuickSurface::engine() noexcept {
  return engine_;
}

QEvent::Type QuickSurface::nativeStateEvent() {
  static const auto type = static_cast<QEvent::Type>(QEvent::registerEventType());

  return type;
}

void QuickSurface::setNativeState(const QVariantMap &state) {
  if (native_state_ == state) {
    return;
  }

  native_state_ = state;
  QEvent event(nativeStateEvent());
  QCoreApplication::sendEvent(&window_, &event);
}

const QVariantMap &QuickSurface::nativeState() const noexcept {
  return native_state_;
}

void QuickSurface::setFocusHandler(std::function<void()> handler) {
  focus_handler_ = std::move(handler);
}

void QuickSurface::requestFocus() {
  if (focus_handler_) {
    focus_handler_();
  } else {
    window_.requestActivate();
  }
}

std::unique_ptr<QObject> QuickSurface::createObject(const QString &module_name,
                                                    const QString &type_name,
                                                    const QVariantMap &properties) {
  QQmlComponent component(&engine_);
  component.loadFromModule(module_name, type_name);

  if (!component.isReady()) {
    qWarning() << component.errors();
    throw std::runtime_error("Unable to load UI component");
  }

  std::unique_ptr<QObject> object{
      component.createWithInitialProperties(properties),
  };

  if (!object) {
    qWarning() << component.errors();
    throw std::runtime_error("Unable to create UI component");
  }

  return object;
}
