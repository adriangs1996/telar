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
  QuickSurface();

  QQuickWindow &window() noexcept;
  QQmlEngine &engine() noexcept;

  std::unique_ptr<QObject>
  createObject(const QString &module, const QString &type, const QVariantMap &properties);
  void setNativeState(const QVariantMap &state);
  const QVariantMap &nativeState() const noexcept;
  void setFocusHandler(std::function<void()> handler);
  void requestFocus();
  static QEvent::Type nativeStateEvent();

protected:
  // Keep engine first and window after, because
  // destructors run in reverse order and we want the engine to hold
  // the reference to its components when destroyed
  QQmlEngine engine_;
  QQuickWindow window_;

private:
  QVariantMap native_state_;
  std::function<void()> focus_handler_;
};
