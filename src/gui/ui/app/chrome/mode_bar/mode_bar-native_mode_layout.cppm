export module telar.gui.ui.app.chrome.mode_bar:native_mode_layout;

import telar.gui.qt;

export namespace telar::gui::qt {

  // Lays out the mode bar: QML measures the badge and hint texts it shows, this places them.
  class [[qt::object, qt::qml_element]] NativeModeLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeModeLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap mode() const;
    void setMode(const QVariantMap& mode);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] qreal pixelSize() const noexcept;
    void setPixelSize(qreal pixel_size);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QString title() const;
    [[nodiscard]] QVariantList hints() const;
    [[nodiscard]] QVariantMap layout() const;

    [[qt::signal]] void modeChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void pixelSizeChanged();
    [[qt::signal]] void measurementsChanged();
    [[qt::signal]] void labelsChanged();
    [[qt::signal]] void layoutChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    void prepareLabels();
    void refreshLayout();

    QVariantMap mode_;
    QVariantMap measurements_;
    QString title_;
    QVariantList hints_;
    QVariantMap layout_;
    qreal ratio_ = 1;
    qreal pixel_size_ = 0;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("mode", &NativeModeLayout::mode).withWrite(&NativeModeLayout::setMode).withNotify(&NativeModeLayout::modeChanged),
        telar::qt::property("ratio", &NativeModeLayout::ratio).withWrite(&NativeModeLayout::setRatio).withNotify(&NativeModeLayout::ratioChanged),
        telar::qt::property("pixelSize", &NativeModeLayout::pixelSize).withWrite(&NativeModeLayout::setPixelSize).withNotify(&NativeModeLayout::pixelSizeChanged),
        telar::qt::property("measurements", &NativeModeLayout::measurements).withWrite(&NativeModeLayout::setMeasurements).withNotify(&NativeModeLayout::measurementsChanged),
        telar::qt::property("title", &NativeModeLayout::title).withNotify(&NativeModeLayout::labelsChanged),
        telar::qt::property("hints", &NativeModeLayout::hints).withNotify(&NativeModeLayout::labelsChanged),
        telar::qt::property("layout", &NativeModeLayout::layout).withNotify(&NativeModeLayout::layoutChanged)
    );
  };

}
