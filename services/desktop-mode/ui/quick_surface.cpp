#include "quick_surface.hpp"
#include "lua_vm.hpp"
#include <QColor>
#include <QDebug>
#include <QDir>
#include <QQmlComponent>
#include <QQmlError>
#include <memory>
#include <stdexcept>

QuickSurface::QuickSurface(lua::Vm &lua_vm) : lua_vm(lua_vm) {}

QQuickWindow &QuickSurface::window() noexcept { return window_; }

QQuickItem &QuickSurface::createItem(const QString &module_name, const QString &type_name,
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

  auto *item = qobject_cast<QQuickItem *>(object.get());
  if (!item) {
    throw std::runtime_error("UI component must be a QQuickItem");
  }

  item->setParent(window_.contentItem());
  item->setParentItem(window_.contentItem());

  object.release();
  return *item;
}
