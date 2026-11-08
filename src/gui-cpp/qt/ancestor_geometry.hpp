#pragma once

#include <QList>
#include <QMetaObject>
#include <QQuickItem>

namespace telar::gui::qt {

class AncestorGeometry {
public:
  explicit AncestorGeometry(QQuickItem &item);
  ~AncestorGeometry();
  AncestorGeometry(const AncestorGeometry &) = delete;
  AncestorGeometry &operator=(const AncestorGeometry &) = delete;
  AncestorGeometry(AncestorGeometry &&) = delete;
  AncestorGeometry &operator=(AncestorGeometry &&) = delete;

  void observe();

private:
  void disconnect();

  QQuickItem &item_;
  QList<QMetaObject::Connection> connections_;
};

}
