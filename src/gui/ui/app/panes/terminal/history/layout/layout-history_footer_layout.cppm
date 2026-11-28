export module telar.gui.ui.app.panes.terminal.history.layout:history_footer_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryFooterLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistoryFooterLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QVariantList hints() const;
    [[nodiscard]] QString range() const;
    [[nodiscard]] QVariantMap layout() const;
    [[nodiscard]] std::size_t hoverTargets(std::uint64_t generation, std::span<application::history::HistoryHoverTarget> destination) const;

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
    QVariantList hints_;
    QString range_;
    application::history::HistoryFooterGeometry geometry_;
    application::history::HistoryFooter footer_;
    application::history::HistoryChoice choice_;
    qreal density_ = 1;
    qreal ratio_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("input", &HistoryFooterLayout::input).withWrite(&HistoryFooterLayout::setInput).withNotify(&HistoryFooterLayout::inputChanged),
        telar::qt::property("measurements", &HistoryFooterLayout::measurements).withWrite(&HistoryFooterLayout::setMeasurements).withNotify(&HistoryFooterLayout::measurementsChanged),
        telar::qt::property("hints", &HistoryFooterLayout::hints).withNotify(&HistoryFooterLayout::labelsChanged),
        telar::qt::property("range", &HistoryFooterLayout::range).withNotify(&HistoryFooterLayout::labelsChanged),
        telar::qt::property("layout", &HistoryFooterLayout::layout).withNotify(&HistoryFooterLayout::layoutChanged)
    );
  };

}
