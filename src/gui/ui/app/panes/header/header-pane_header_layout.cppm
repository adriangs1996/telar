export module telar.gui.ui.app.panes.header:pane_header_layout;

import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] PaneHeaderLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit PaneHeaderLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] qreal bandHeight() const noexcept;
    void setBandHeight(qreal height);
    [[nodiscard]] QVariantMap style() const;
    [[nodiscard]] QRectF indexBounds() const noexcept;
    [[nodiscard]] QRectF nameBounds() const noexcept;
    [[nodiscard]] QRectF pausedBounds() const noexcept;
    [[nodiscard]] QRectF chipBounds() const noexcept;
    [[nodiscard]] QRectF progressBounds() const noexcept;
    [[nodiscard]] bool compactProgress() const noexcept;

    [[qt::signal]] void measurementsChanged();
    [[qt::signal]] void metricsChanged();
    [[qt::signal]] void layoutChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    [[nodiscard]] QRectF logical(Rect bounds) const noexcept;
    void refreshLayout();

    QVariantMap measurements_;
    application::workbench::PaneHeaderGeometry layout_;
    qreal ratio_ = 1;
    qreal band_height_ = static_cast<qreal>(ChromeMetrics::logical_pane_header);
    qreal density_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("measurements", &PaneHeaderLayout::measurements).withWrite(&PaneHeaderLayout::setMeasurements).withNotify(&PaneHeaderLayout::measurementsChanged),
        telar::qt::property("ratio", &PaneHeaderLayout::ratio).withWrite(&PaneHeaderLayout::setRatio).withNotify(&PaneHeaderLayout::metricsChanged),
        telar::qt::property("bandHeight", &PaneHeaderLayout::bandHeight).withWrite(&PaneHeaderLayout::setBandHeight).withNotify(&PaneHeaderLayout::metricsChanged),
        telar::qt::property("style", &PaneHeaderLayout::style).withNotify(&PaneHeaderLayout::metricsChanged),
        telar::qt::property("indexBounds", &PaneHeaderLayout::indexBounds).withNotify(&PaneHeaderLayout::layoutChanged),
        telar::qt::property("nameBounds", &PaneHeaderLayout::nameBounds).withNotify(&PaneHeaderLayout::layoutChanged),
        telar::qt::property("pausedBounds", &PaneHeaderLayout::pausedBounds).withNotify(&PaneHeaderLayout::layoutChanged),
        telar::qt::property("chipBounds", &PaneHeaderLayout::chipBounds).withNotify(&PaneHeaderLayout::layoutChanged),
        telar::qt::property("progressBounds", &PaneHeaderLayout::progressBounds).withNotify(&PaneHeaderLayout::layoutChanged),
        telar::qt::property("compactProgress", &PaneHeaderLayout::compactProgress).withNotify(&PaneHeaderLayout::layoutChanged)
    );
  };

}
