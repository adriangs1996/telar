#pragma once

#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>

namespace lua {
  struct Vm;
}

struct QuickSurface {
  explicit QuickSurface(lua::Vm &lua_vm);

  QQuickWindow &window() noexcept;

  QQuickItem &createItem(const QString &module_name, const QString &type_name,
                         const QVariantMap &properties);

protected:
  // Keep engine first and window after, because
  // destructors run in reverse order and we want the engine to hold
  // the reference to its components when destroyed
  lua::Vm &lua_vm;
  QQmlEngine engine_;
  QQuickWindow window_;
};
