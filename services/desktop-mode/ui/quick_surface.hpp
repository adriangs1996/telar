#pragma once

#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>

struct QuickSurface {
  QuickSurface();

  QQuickWindow &window() noexcept;

  QQuickItem &createItem(const QString &module_name, const QString &type_name,
                         const QVariantMap &properties);

private:
  // Keep engine first and window after, because
  // destructors run in reverse order and we want the engine to hold
  // the reference to its components when destroyed
  QQmlEngine engine_;
  QQuickWindow window_;
};
