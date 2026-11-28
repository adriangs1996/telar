export module telar.gui.ui.design.controls:native_tab_activity;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.scene;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeTabActivity : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    explicit NativeTabActivity(QQuickItem* parent = nullptr);
    ~NativeTabActivity() override;
    NativeTabActivity(const NativeTabActivity&) = delete;
    NativeTabActivity& operator=(const NativeTabActivity&) = delete;
    NativeTabActivity(NativeTabActivity&&) = delete;
    NativeTabActivity& operator=(NativeTabActivity&&) = delete;
    [[nodiscard]] QVariantMap record() const;
    void setRecord(const QVariantMap& record);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] bool running() const noexcept;
    void setRunning(bool running);
    [[nodiscard]] bool compact() const noexcept;
    void setCompact(bool compact);
    [[nodiscard]] qreal fraction() const noexcept;
    [[nodiscard]] qreal turns() const noexcept;

    [[qt::signal]] void recordChanged();
    [[qt::signal]] void colorChanged();
    [[qt::signal]] void ratioChanged();
    [[qt::signal]] void runningChanged();
    [[qt::signal]] void animationChanged();
    [[qt::signal]] void compactChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;

  private:
    friend class WindowAnimationItems<NativeTabActivity>;
    void bindClock();
    void synchronize();
    void sample(std::uint64_t now_ns);
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    QVariantMap record_;
    QColor color_ = Qt::white;
    qreal ratio_ = 1;
    application::activity::TabActivity::Kind kind_ = application::activity::TabActivity::Kind::none;
    application::workbench::ProgressSample progress_;
    application::workbench::ProgressMotion motion_;
    float fraction_ = 0;
    float turns_ = 0;
    bool running_ = true;
    bool compact_ = true;
    bool animation_notification_pending_ = false;
    QPointer<WindowAnimationClock> clock_;
    tbc::val_self<AncestorGeometry> ancestors_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("record", &NativeTabActivity::record).withWrite(&NativeTabActivity::setRecord).withNotify(&NativeTabActivity::recordChanged).required(),
        telar::qt::property("color", &NativeTabActivity::color).withWrite(&NativeTabActivity::setColor).withNotify(&NativeTabActivity::colorChanged),
        telar::qt::property("ratio", &NativeTabActivity::ratio).withWrite(&NativeTabActivity::setRatio).withNotify(&NativeTabActivity::ratioChanged),
        telar::qt::property("running", &NativeTabActivity::running).withWrite(&NativeTabActivity::setRunning).withNotify(&NativeTabActivity::runningChanged),
        telar::qt::property("compact", &NativeTabActivity::compact).withWrite(&NativeTabActivity::setCompact).withNotify(&NativeTabActivity::compactChanged),
        telar::qt::property("fraction", &NativeTabActivity::fraction).withNotify(&NativeTabActivity::animationChanged),
        telar::qt::property("turns", &NativeTabActivity::turns).withNotify(&NativeTabActivity::animationChanged)
    );
  };

}
