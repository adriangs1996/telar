export module telar.gui.ui.design.controls:native_rounded_rectangle;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.scene;
import telar.base.ds;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeRoundedRectangle : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeRoundedRectangle(QQuickItem* parent = nullptr);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] bool replaceBackground() const noexcept;
    void setReplaceBackground(bool replace);
    [[nodiscard]] QColor backdropColor() const;
    void setBackdropColor(const QColor& color);
    [[nodiscard]] QColor borderColor() const;
    void setBorderColor(const QColor& color);
    [[nodiscard]] qreal borderAlpha() const noexcept;
    void setBorderAlpha(qreal alpha);
    [[nodiscard]] qreal radius() const noexcept;
    void setRadius(qreal radius);
    [[nodiscard]] qreal borderWidth() const noexcept;
    void setBorderWidth(qreal width);
    [[nodiscard]] QRectF paintClip() const;
    void setPaintClip(const QRectF& bounds);
    void resetPaintClip();

    [[qt::signal]] void colorChanged();
    [[qt::signal]] void compositionChanged();
    [[qt::signal]] void borderColorChanged();
    [[qt::signal]] void borderAlphaChanged();
    [[qt::signal]] void radiusChanged();
    [[qt::signal]] void borderWidthChanged();
    [[qt::signal]] void paintClipChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    QColor color_ = Qt::transparent;
    QColor border_color_ = Qt::transparent;
    QColor backdrop_color_ = Qt::transparent;
    bool replace_background_ = false;
    qreal radius_ = 0;
    qreal border_width_ = 0;
    float border_alpha_ = 1;
    tbc::val_self<AncestorGeometry> ancestors_;
    ds::Option<QRectF> paint_clip_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("color", &NativeRoundedRectangle::color).withWrite(&NativeRoundedRectangle::setColor).withNotify(&NativeRoundedRectangle::colorChanged),
        telar::qt::property("replaceBackground", &NativeRoundedRectangle::replaceBackground).withWrite(&NativeRoundedRectangle::setReplaceBackground).withNotify(&NativeRoundedRectangle::compositionChanged),
        telar::qt::property("backdropColor", &NativeRoundedRectangle::backdropColor).withWrite(&NativeRoundedRectangle::setBackdropColor).withNotify(&NativeRoundedRectangle::compositionChanged),
        telar::qt::property("borderColor", &NativeRoundedRectangle::borderColor).withWrite(&NativeRoundedRectangle::setBorderColor).withNotify(&NativeRoundedRectangle::borderColorChanged),
        telar::qt::property("borderAlpha", &NativeRoundedRectangle::borderAlpha).withWrite(&NativeRoundedRectangle::setBorderAlpha).withNotify(&NativeRoundedRectangle::borderAlphaChanged),
        telar::qt::property("radius", &NativeRoundedRectangle::radius).withWrite(&NativeRoundedRectangle::setRadius).withNotify(&NativeRoundedRectangle::radiusChanged),
        telar::qt::property("borderWidth", &NativeRoundedRectangle::borderWidth).withWrite(&NativeRoundedRectangle::setBorderWidth).withNotify(&NativeRoundedRectangle::borderWidthChanged),
        telar::qt::property("paintClip", &NativeRoundedRectangle::paintClip).withWrite(&NativeRoundedRectangle::setPaintClip).withNotify(&NativeRoundedRectangle::paintClipChanged).withReset(&NativeRoundedRectangle::resetPaintClip)
    );
  };

}
