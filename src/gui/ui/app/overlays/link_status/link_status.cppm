export module telar.gui.ui.app.overlays.link_status;

import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;

export namespace telar::gui::qt {

  // The veil over the terminals while the active machine's runtime link is down: its headline,
  // the failure that explains it, and where both are drawn.
  //
  // It reads the store and the display the window pushes. The window tells it when the active
  // machine's link moved, or the active machine itself.
  class [[qt::object, qt_qml_named("LinkStatusController"), qt_qml_uncreatable("Use the window's link status")]] LinkStatusController final : public QObject {
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

    explicit LinkStatusController(Store& store, QObject* parent = nullptr);
    ~LinkStatusController() override = default;
    LinkStatusController(const LinkStatusController&) = delete;
    LinkStatusController& operator=(const LinkStatusController&) = delete;
    LinkStatusController(LinkStatusController&&) = delete;
    LinkStatusController& operator=(LinkStatusController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;

    // The active machine's link moved, or another machine became the active one.
    void publish();
    void setDisplay(const application::window::DisplayMetrics& display);

    [[qt::signal]] void changed();

  private:
    Store& store_;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &LinkStatusController::state).withNotify(&LinkStatusController::changed),
        telar::qt::property("geometry", &LinkStatusController::geometry).withNotify(&LinkStatusController::changed)
    );
  };

}
