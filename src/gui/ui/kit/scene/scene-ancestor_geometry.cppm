export module telar.gui.ui.kit.scene:ancestor_geometry;

import telar.gui.qt;

export namespace telar::gui::qt {

  class AncestorGeometry {
  public:
    explicit AncestorGeometry(QQuickItem& item);
    ~AncestorGeometry();
    AncestorGeometry(const AncestorGeometry&) = delete;
    AncestorGeometry& operator=(const AncestorGeometry&) = delete;
    AncestorGeometry(AncestorGeometry&&) = delete;
    AncestorGeometry& operator=(AncestorGeometry&&) = delete;

    void observe();

  private:
    void disconnect();

    QQuickItem& item_;
    QList<QMetaObject::Connection> connections_;
  };

}
