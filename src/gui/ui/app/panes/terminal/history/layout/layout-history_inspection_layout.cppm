export module telar.gui.ui.app.panes.terminal.history.layout:history_inspection_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryInspectionLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistoryInspectionLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantList advances() const;
    void setAdvances(const QVariantList& advances);
    [[nodiscard]] QVariantMap layout() const;
    [[nodiscard]] int scroll() const;
    void setScroll(int scroll);
    [[nodiscard]] std::size_t hoverTargets(std::uint64_t generation, std::span<application::history::HistoryHoverTarget> destination) const;

    [[qt::signal]] void inputChanged();
    [[qt::signal]] void advancesChanged();
    [[qt::signal]] void layoutChanged();
    [[qt::signal]] void scrollChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void wheelEvent(QWheelEvent* event) override;

  private:
    [[nodiscard]] QRectF logical(Rect area) const noexcept;
    [[nodiscard]] float physical(const QVariant& value) const;
    [[nodiscard]] ChromeMetrics metrics(qreal ratio) const;
    [[nodiscard]] QVariantMap projectLine(const application::history::HistoryInspectionLine& line, const application::history::HistoryInspectionGeometry& geometry, std::uint16_t index) const;
    [[nodiscard]] QVariantMap prepareContent(const application::history::HistoryInspectionGeometry& geometry);
    [[nodiscard]] QVariantList prepareButtons(const application::history::HistoryInspectionGeometry& geometry, ChromeMetrics chrome);

    QVariantMap input_;
    QVariantList advances_;
    QVariantMap layout_;
    ds::Array<Rect, application::history::HistoryInspectionGeometry::maximum_actions> button_bounds_{};
    application::history::HistoryChoice choice_;
    bool pane_open_ = false;
    bool ready_ = false;
    qreal density_ = 1;
    int scroll_ = 0;
    WheelAccumulator wheel_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("input", &HistoryInspectionLayout::input).withWrite(&HistoryInspectionLayout::setInput).withNotify(&HistoryInspectionLayout::inputChanged),
        telar::qt::property("advances", &HistoryInspectionLayout::advances).withWrite(&HistoryInspectionLayout::setAdvances).withNotify(&HistoryInspectionLayout::advancesChanged),
        telar::qt::property("layout", &HistoryInspectionLayout::layout).withNotify(&HistoryInspectionLayout::layoutChanged),
        telar::qt::property("scroll", &HistoryInspectionLayout::scroll).withWrite(&HistoryInspectionLayout::setScroll).withNotify(&HistoryInspectionLayout::scrollChanged)
    );
  };

}
