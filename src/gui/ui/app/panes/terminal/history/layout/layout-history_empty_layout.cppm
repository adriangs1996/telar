export module telar.gui.ui.app.panes.terminal.history.layout:history_empty_layout;

import telar.gui.qt;
import telar.gui.application;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryEmptyLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistoryEmptyLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QString title() const;
    [[nodiscard]] QString subtitle() const;
    [[nodiscard]] QString action() const;
    [[nodiscard]] bool emphasized() const noexcept;
    [[nodiscard]] QVariantMap layout() const;

    [[qt::signal]] void inputChanged();
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

    QVariantMap input_;
    QVariantMap measurements_;
    application::history::HistoryEmpty content_;
    application::history::HistoryEmptyGeometry geometry_;
    qreal density_ = 1;
    qreal ratio_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("input", &HistoryEmptyLayout::input).withWrite(&HistoryEmptyLayout::setInput).withNotify(&HistoryEmptyLayout::inputChanged),
        telar::qt::property("measurements", &HistoryEmptyLayout::measurements).withWrite(&HistoryEmptyLayout::setMeasurements).withNotify(&HistoryEmptyLayout::measurementsChanged),
        telar::qt::property("title", &HistoryEmptyLayout::title).withNotify(&HistoryEmptyLayout::labelsChanged),
        telar::qt::property("subtitle", &HistoryEmptyLayout::subtitle).withNotify(&HistoryEmptyLayout::labelsChanged),
        telar::qt::property("action", &HistoryEmptyLayout::action).withNotify(&HistoryEmptyLayout::labelsChanged),
        telar::qt::property("emphasized", &HistoryEmptyLayout::emphasized).withNotify(&HistoryEmptyLayout::labelsChanged),
        telar::qt::property("layout", &HistoryEmptyLayout::layout).withNotify(&HistoryEmptyLayout::layoutChanged)
    );
  };

}
