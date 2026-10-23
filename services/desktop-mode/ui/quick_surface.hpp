#pragma once

#include <QEvent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>
#include <functional>
#include <memory>

struct QuickSurface {
  // Surfaces share one engine, which caches every loaded QML type: an engine of its own would
  // cost each surface its own type cache and JavaScript heap. The engine must outlive the surface.
  explicit QuickSurface(QQmlEngine &engine);

  QQuickWindow &window() noexcept;
  QQmlEngine &engine() noexcept;

  std::unique_ptr<QObject>
  createObject(const QString &module, const QString &type, const QVariantMap &properties);
  void setNativeState(const QVariantMap &state);
  const QVariantMap &nativeState() const noexcept;
  void setFocusHandler(std::function<void()> handler);
  void requestFocus();
  // The native backend decides whether and how a surface takes another width; without a handler
  // the request does nothing.
  void setWidthHandler(std::function<void(double)> handler);
  void requestWidth(double width);
  static QEvent::Type nativeStateEvent();

protected:
  QQmlEngine &engine_;
  QQuickWindow window_;

private:
  QVariantMap native_state_;
  std::function<void()> focus_handler_;
  std::function<void(double)> width_handler_;
};
