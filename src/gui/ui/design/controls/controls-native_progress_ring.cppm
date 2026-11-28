export module telar.gui.ui.design.controls:native_progress_ring;

import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeProgressRing : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    // Zero derives the stroke from the ring's side.
    // Unset keeps the faint track of the ring's colour; a transparent colour draws no track.
    explicit NativeProgressRing(QQuickItem* parent = nullptr);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal fraction() const noexcept;
    void setFraction(qreal fraction);
    [[nodiscard]] qreal turns() const noexcept;
    void setTurns(qreal turns);
    [[nodiscard]] qreal strokeWidth() const noexcept;
    void setStrokeWidth(qreal width);
    [[nodiscard]] QColor trackColor() const;
    void setTrackColor(const QColor& color);

    [[qt::signal]] void colorChanged();
    [[qt::signal]] void fractionChanged();
    [[qt::signal]] void turnsChanged();
    [[qt::signal]] void strokeWidthChanged();
    [[qt::signal]] void trackColorChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;

  private:
    QColor color_ = Qt::white;
    qreal fraction_ = 0;
    qreal turns_ = 0;
    qreal stroke_width_ = 0;
    QColor track_color_;
    tbc::val_self<AncestorGeometry> ancestors_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("color", &NativeProgressRing::color).withWrite(&NativeProgressRing::setColor).withNotify(&NativeProgressRing::colorChanged),
        telar::qt::property("fraction", &NativeProgressRing::fraction).withWrite(&NativeProgressRing::setFraction).withNotify(&NativeProgressRing::fractionChanged),
        telar::qt::property("turns", &NativeProgressRing::turns).withWrite(&NativeProgressRing::setTurns).withNotify(&NativeProgressRing::turnsChanged),
        telar::qt::property("strokeWidth", &NativeProgressRing::strokeWidth).withWrite(&NativeProgressRing::setStrokeWidth).withNotify(&NativeProgressRing::strokeWidthChanged),
        telar::qt::property("trackColor", &NativeProgressRing::trackColor).withWrite(&NativeProgressRing::setTrackColor).withNotify(&NativeProgressRing::trackColorChanged)
    );
  };

}
