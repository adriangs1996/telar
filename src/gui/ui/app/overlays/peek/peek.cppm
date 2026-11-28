export module telar.gui.ui.app.overlays.peek;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The peek at an agent from its activity card: the agent's recent screen and facts, and a
  // message to send it without leaving the current tab.
  //
  // It reads the store, the target it was opened from and the display the window pushes. The
  // window opens the peek; it asks to close once its agent is gone or the message is sent.
  class [[qt::object, qt_qml_named("PeekController"), qt_qml_uncreatable("Use the window's peek")]] PeekController final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

    explicit PeekController(Store& store, QObject* parent = nullptr);
    ~PeekController() override = default;
    PeekController(const PeekController&) = delete;
    PeekController& operator=(const PeekController&) = delete;
    PeekController(PeekController&&) = delete;
    PeekController& operator=(PeekController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    [[qt::invokable]] void search(const QString& text);
    [[qt::invokable]] void submit(const QString& revision);
    [[qt::invokable]] void reportLimit(qulonglong requested_bytes);

    // Peeks at the agent the card targets; false when the session cannot.
    bool open(const application::machines::MachineActivityTarget& target);
    // Asks to close once the peek no longer shows the agent it was opened from.
    void synchronize();
    // The dialog closed: the session stops reading the agent's screen.
    void forget();
    void setDisplay(const application::window::DisplayMetrics& display);
    // A new window presents the session; a peek opened in another one is stale.
    void setWindowGeneration(std::uint64_t generation) noexcept;

    [[qt::signal]] void changed();
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    struct Origin {
      application::machines::MachineActivityTarget target;
      std::uint64_t window;
    };

    [[nodiscard]] bool valid() const;

    Store& store_;
    ds::Option<Origin> origin_;
    QString editor_;
    std::uint64_t window_generation_ = 0;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &PeekController::state).withNotify(&PeekController::changed),
        telar::qt::property("geometry", &PeekController::geometry).withNotify(&PeekController::changed)
    );
  };

}
