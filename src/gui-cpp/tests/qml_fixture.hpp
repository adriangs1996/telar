#pragma once

#include <QList>
#include <QObject>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtCore/qobject.h>
#include <memory>
#include <stdexcept>

namespace telar::gui::test {

inline QList<QQuickItem *> visualItems(QQuickItem &root, const QString &object_name) {
  QList<QQuickItem *> pending{&root};
  QList<QQuickItem *> matches;
  while (!pending.isEmpty()) {
    auto *item = pending.takeLast();
    if (item->objectName() == object_name) {
      matches.append(item);
    }

    pending.append(item->childItems());
  }

  return matches;
}

inline std::unique_ptr<QQuickItem> createChrome(QQmlEngine &engine, const QString &type, const QVariantMap &properties) {
  QQmlComponent component{&engine};
  component.loadFromModule(QStringLiteral("Telar.Gui"), type);
  auto object = std::unique_ptr<QObject>{component.createWithInitialProperties(properties)};
  const auto *item = qobject_cast<QQuickItem *>(object.get());
  if (item == nullptr) {
    throw std::runtime_error{component.errorString().toStdString()};
  }

  return std::unique_ptr<QQuickItem>{dynamic_cast<QQuickItem *>(object.release())};
}

}
