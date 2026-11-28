export module telar.gui.tests.qml_fixture;

import std;
import telar.gui.qt;

export namespace telar::gui::test {

  inline QList<QQuickItem*> visualItems(QQuickItem& root, const QString& object_name) {
    QList<QQuickItem*> pending{&root};
    QList<QQuickItem*> matches;

    while (!pending.isEmpty()) {
      auto* item = pending.takeLast();
      if (item->objectName() == object_name) {
        matches.append(item);
      }

      pending.append(item->childItems());
    }

    return matches;
  }

  inline std::unique_ptr<QQuickItem> createChrome(QQmlEngine& engine, const QString& type, const QVariantMap& properties) {
    using Qt::StringLiterals::operator""_s;
    QQmlComponent component{&engine};

    component.loadFromModule(u"Telar.Gui"_s, type);
    auto object = std::unique_ptr<QObject>{component.createWithInitialProperties(properties)};
    const auto* item = qobject_cast<QQuickItem*>(object.get());
    if (item == nullptr) {
      throw std::runtime_error{component.errorString().toStdString()};
    }

    return std::unique_ptr<QQuickItem>{dynamic_cast<QQuickItem*>(object.release())};
  }

}
