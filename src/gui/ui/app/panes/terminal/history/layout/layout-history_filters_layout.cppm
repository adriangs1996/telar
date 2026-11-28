export module telar.gui.ui.app.panes.terminal.history.layout:history_filters_layout;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryFiltersLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    static constexpr std::size_t target_count = application::history::history_filter_target_count;

    explicit HistoryFiltersLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QVariantList scopeChoices() const;
    [[nodiscard]] QVariantList authorChoices() const;
    [[nodiscard]] QStringList keyLabels() const;
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
    [[nodiscard]] QVariantMap chipRecord(const application::history::HistoryFilterChipGeometry& chip) const;

    QVariantMap input_;
    QVariantMap measurements_;
    QVariantList scope_choices_;
    QVariantList author_choices_;
    QStringList key_labels_;
    application::history::HistoryFilterGeometry geometry_;
    qreal density_ = 1;
    qreal ratio_ = 1;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("input", &HistoryFiltersLayout::input).withWrite(&HistoryFiltersLayout::setInput).withNotify(&HistoryFiltersLayout::inputChanged),
        telar::qt::property("measurements", &HistoryFiltersLayout::measurements).withWrite(&HistoryFiltersLayout::setMeasurements).withNotify(&HistoryFiltersLayout::measurementsChanged),
        telar::qt::property("scopeChoices", &HistoryFiltersLayout::scopeChoices).withNotify(&HistoryFiltersLayout::labelsChanged),
        telar::qt::property("authorChoices", &HistoryFiltersLayout::authorChoices).withNotify(&HistoryFiltersLayout::labelsChanged),
        telar::qt::property("keyLabels", &HistoryFiltersLayout::keyLabels).withNotify(&HistoryFiltersLayout::labelsChanged),
        telar::qt::property("layout", &HistoryFiltersLayout::layout).withNotify(&HistoryFiltersLayout::layoutChanged)
    );
  };

}
