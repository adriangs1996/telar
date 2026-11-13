#include "ancestor_geometry.hpp"
#include <QObject>
#include <QQuickItem>

namespace telar::gui::qt {

AncestorGeometry::AncestorGeometry(QQuickItem &item)
    : item_(item) {
  observe();
}

AncestorGeometry::~AncestorGeometry() {
  disconnect();
}

void AncestorGeometry::disconnect() {
  for (const auto &connection : connections_) {
    QObject::disconnect(connection);
  }

  connections_.clear();
}

void AncestorGeometry::observe() {
  disconnect();
  for (const auto *ancestor = item_.parentItem(); ancestor != nullptr; ancestor = ancestor->parentItem()) {
    for (const auto changed : {&QQuickItem::xChanged, &QQuickItem::yChanged, &QQuickItem::widthChanged, &QQuickItem::heightChanged, &QQuickItem::rotationChanged, &QQuickItem::scaleChanged}) {
      connections_.append(QObject::connect(ancestor, changed, &item_, &QQuickItem::update));
    }

    connections_.append(QObject::connect(ancestor, &QQuickItem::transformOriginChanged, &item_, &QQuickItem::update));
    connections_.append(QObject::connect(ancestor, &QQuickItem::parentChanged, &item_, [this] {
      observe();
      item_.update();
    }));
  }
}

}
