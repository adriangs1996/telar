export module telar.gui.ui.app.panes.terminal.history.layout:history_loading_layout;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] HistoryLoadingLayout : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit HistoryLoadingLayout(QQuickItem* parent = nullptr);
    ~HistoryLoadingLayout() override;
    HistoryLoadingLayout(const HistoryLoadingLayout&) = delete;
    HistoryLoadingLayout& operator=(const HistoryLoadingLayout&) = delete;
    HistoryLoadingLayout(HistoryLoadingLayout&&) = delete;
    HistoryLoadingLayout& operator=(HistoryLoadingLayout&&) = delete;
    [[nodiscard]] bool waiting() const noexcept;
    void setWaiting(bool waiting);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] bool cueVisible() const noexcept;
    [[nodiscard]] qreal rowsOpacity() const noexcept;
    [[nodiscard]] QRectF line() const noexcept;

    [[qt::signal]] void waitingChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void frameChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;

  private:
    friend class WindowAnimationItems<HistoryLoadingLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void synchronize();
    void bindClock();

    QPointer<WindowAnimationClock> clock_;
    application::window::LoadingCue cue_;
    QRectF line_;
    qreal ratio_ = 1;
    bool waiting_ = false;
    bool cue_visible_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("waiting", &HistoryLoadingLayout::waiting).withWrite(&HistoryLoadingLayout::setWaiting).withNotify(&HistoryLoadingLayout::waitingChanged),
        telar::qt::property("ratio", &HistoryLoadingLayout::ratio).withWrite(&HistoryLoadingLayout::setRatio).withNotify(&HistoryLoadingLayout::ratioChanged),
        telar::qt::property("cueVisible", &HistoryLoadingLayout::cueVisible).withNotify(&HistoryLoadingLayout::frameChanged),
        telar::qt::property("rowsOpacity", &HistoryLoadingLayout::rowsOpacity).withNotify(&HistoryLoadingLayout::frameChanged),
        telar::qt::property("line", &HistoryLoadingLayout::line).withNotify(&HistoryLoadingLayout::frameChanged)
    );
  };

}
