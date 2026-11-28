export module telar.gui.ui.app.panes.terminal.history.layout:history_meta_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryMetaLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistoryMetaLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QVariantList facts() const;
    [[nodiscard]] QVariantList actions() const;
    [[nodiscard]] QVariantMap layout() const;
    [[nodiscard]] application::history::HistoryActionSurface actionSurface(std::uint64_t generation) const;

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
    [[nodiscard]] QRectF logical(Rect area) const noexcept;

    QVariantMap input_;
    QVariantMap measurements_;
    QVariantList facts_;
    QVariantList actions_;
    application::history::HistoryMetaGeometry geometry_;
    qreal density_ = 1;
    qreal ratio_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("input", &HistoryMetaLayout::input).withWrite(&HistoryMetaLayout::setInput).withNotify(&HistoryMetaLayout::inputChanged),
        telar::qt::property("measurements", &HistoryMetaLayout::measurements).withWrite(&HistoryMetaLayout::setMeasurements).withNotify(&HistoryMetaLayout::measurementsChanged),
        telar::qt::property("facts", &HistoryMetaLayout::facts).withNotify(&HistoryMetaLayout::labelsChanged),
        telar::qt::property("actions", &HistoryMetaLayout::actions).withNotify(&HistoryMetaLayout::labelsChanged),
        telar::qt::property("layout", &HistoryMetaLayout::layout).withNotify(&HistoryMetaLayout::layoutChanged)
    );
  };

}
