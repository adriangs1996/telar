export module telar.phase0.rounded_rect;

import std;
import telar.qt;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeRoundedRectangle : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;

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

    [[qt::invokable]] [[nodiscard]] qreal effectiveRadius() const noexcept;

    [[qt::signal]] void colorChanged();
    [[qt::signal]] void compositionChanged();
    [[qt::signal]] void borderColorChanged();
    [[qt::signal]] void borderAlphaChanged();
    [[qt::signal]] void radiusChanged();
    [[qt::signal]] void borderWidthChanged();
    [[qt::signal]] void paintClipChanged();

    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("color", &NativeRoundedRectangle::color, &NativeRoundedRectangle::setColor, &NativeRoundedRectangle::colorChanged),
        telar::qt::property("replaceBackground", &NativeRoundedRectangle::replaceBackground, &NativeRoundedRectangle::setReplaceBackground, &NativeRoundedRectangle::compositionChanged),
        telar::qt::property("backdropColor", &NativeRoundedRectangle::backdropColor, &NativeRoundedRectangle::setBackdropColor, &NativeRoundedRectangle::compositionChanged),
        telar::qt::property("borderColor", &NativeRoundedRectangle::borderColor, &NativeRoundedRectangle::setBorderColor, &NativeRoundedRectangle::borderColorChanged),
        telar::qt::property("borderAlpha", &NativeRoundedRectangle::borderAlpha, &NativeRoundedRectangle::setBorderAlpha, &NativeRoundedRectangle::borderAlphaChanged),
        telar::qt::property("radius", &NativeRoundedRectangle::radius, &NativeRoundedRectangle::setRadius, &NativeRoundedRectangle::radiusChanged),
        telar::qt::property("borderWidth", &NativeRoundedRectangle::borderWidth, &NativeRoundedRectangle::setBorderWidth, &NativeRoundedRectangle::borderWidthChanged),
        telar::qt::property("paintClip", &NativeRoundedRectangle::paintClip, &NativeRoundedRectangle::setPaintClip, &NativeRoundedRectangle::paintClipChanged).withReset(&NativeRoundedRectangle::resetPaintClip)
    );

  private:
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    QColor color_ = Qt::transparent;
    QColor border_color_ = Qt::transparent;
    QColor backdrop_color_ = Qt::transparent;
    bool replace_background_ = false;
    qreal radius_ = 0;
    qreal border_width_ = 0;
    float border_alpha_ = 1;
    std::optional<QRectF> paint_clip_;
  };

}
