export module telar.gui.ui.design.controls:native_agent_status;

import std;
import telar.gui.qt;
import telar.gui.foundation.model;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.gui.ui.kit.scene;

export namespace telar::gui::qt {

  class [[qt::object, qt::qml_element]] NativeAgentStatus : public QQuickItem {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    enum class [[qt::qenum]] DisplayMode : quint8 {
      card,
      pane_chip,
    };
    explicit NativeAgentStatus(QQuickItem* parent = nullptr);
    ~NativeAgentStatus() override;
    NativeAgentStatus(const NativeAgentStatus&) = delete;
    NativeAgentStatus& operator=(const NativeAgentStatus&) = delete;
    NativeAgentStatus(NativeAgentStatus&&) = delete;
    NativeAgentStatus& operator=(NativeAgentStatus&&) = delete;
    [[nodiscard]] QVariantMap record() const;
    void setRecord(const QVariantMap& record);
    [[nodiscard]] QString statusText() const;
    [[nodiscard]] qreal animatedAlpha() const noexcept;
    [[nodiscard]] bool running() const noexcept;
    void setRunning(bool running);
    [[nodiscard]] DisplayMode displayMode() const noexcept;
    void setDisplayMode(DisplayMode mode);

    [[qt::signal]] void recordChanged();
    [[qt::signal]] void statusTextChanged();
    [[qt::signal]] void animatedAlphaChanged();
    [[qt::signal]] void runningChanged();
    [[qt::signal]] void displayModeChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;

  private:
    friend class WindowAnimationItems<NativeAgentStatus>;
    void bindClock();
    void synchronize();
    void sample(std::uint64_t now_ns);
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    QVariantMap record_;
    QString status_text_;
    StatusAgeInterval interval_;
    AgentStatus status_ = AgentStatus::unknown;
    AgentBlockedReason reason_ = AgentBlockedReason::none;
    qreal animated_alpha_ = 1;
    bool connected_ = false;
    bool running_ = true;
    DisplayMode display_mode_ = DisplayMode::card;
    QPointer<WindowAnimationClock> clock_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("record", &NativeAgentStatus::record).withWrite(&NativeAgentStatus::setRecord).withNotify(&NativeAgentStatus::recordChanged).required(),
        telar::qt::property("statusText", &NativeAgentStatus::statusText).withNotify(&NativeAgentStatus::statusTextChanged),
        telar::qt::property("animatedAlpha", &NativeAgentStatus::animatedAlpha).withNotify(&NativeAgentStatus::animatedAlphaChanged),
        telar::qt::property("running", &NativeAgentStatus::running).withWrite(&NativeAgentStatus::setRunning).withNotify(&NativeAgentStatus::runningChanged),
        telar::qt::property("displayMode", &NativeAgentStatus::displayMode).withWrite(&NativeAgentStatus::setDisplayMode).withNotify(&NativeAgentStatus::displayModeChanged)
    );
  };

}
