#include "quick_surface.hpp"
#include <QColor>
#include <QDebug>
#include <QQmlComponent>
#include <QQmlError>
#include <memory>
#include <stdexcept>

QuickSurface::QuickSurface() {
  window_.setColor(QColor("#263449"));

  createItem("QtQuick", "Text",
             {
                 {"text", QStringLiteral("Telar")},
                 {"color", QColor("#cdd6f4")},
                 {"x", 12},
                 {"y", 8},
             });
}

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
