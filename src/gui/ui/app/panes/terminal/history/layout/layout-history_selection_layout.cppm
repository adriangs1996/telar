export module telar.gui.ui.app.panes.terminal.history.layout:history_selection_layout;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistorySelectionLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistorySelectionLayout(QQuickItem* parent = nullptr);
    ~HistorySelectionLayout() override;
    HistorySelectionLayout(const HistorySelectionLayout&) = delete;
    HistorySelectionLayout& operator=(const HistorySelectionLayout&) = delete;
    HistorySelectionLayout(HistorySelectionLayout&&) = delete;
    HistorySelectionLayout& operator=(HistorySelectionLayout&&) = delete;
    [[nodiscard]] QVariantMap selection() const;
    void setSelection(const QVariantMap& selection);
    [[nodiscard]] qreal selectedOpen() const noexcept;
    [[nodiscard]] int leavingIndex() const noexcept;
    [[nodiscard]] QString leavingKey() const;
    [[nodiscard]] qreal leavingOpen() const noexcept;

    [[qt::signal]] void selectionChanged();
    [[qt::signal]] void frameChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<HistorySelectionLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void prepareFrame();
    void bindClock();
    void synchronize();

    QVariantMap selection_;
    QPointer<WindowAnimationClock> clock_;
    QMetaObject::Connection frame_connection_;
    application::history::HistorySelectionMotion motion_;
    application::history::HistoryExpansion expansion_;
    QString leaving_key_;
    ds::Option<std::uint64_t> generation_;
    ds::Option<application::history::HistoryPosition> selected_;
    ds::Option<std::uint64_t> next_sample_ns_;
    bool dirty_ = true;
    bool frame_requested_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("selection", &HistorySelectionLayout::selection).withWrite(&HistorySelectionLayout::setSelection).withNotify(&HistorySelectionLayout::selectionChanged),
        telar::qt::property("selectedOpen", &HistorySelectionLayout::selectedOpen).withNotify(&HistorySelectionLayout::frameChanged),
        telar::qt::property("leavingIndex", &HistorySelectionLayout::leavingIndex).withNotify(&HistorySelectionLayout::frameChanged),
        telar::qt::property("leavingKey", &HistorySelectionLayout::leavingKey).withNotify(&HistorySelectionLayout::frameChanged),
        telar::qt::property("leavingOpen", &HistorySelectionLayout::leavingOpen).withNotify(&HistorySelectionLayout::frameChanged)
    );
  };

}
