export module telar.gui.ui.app.chrome:sidebar_controller;

import telar.gui.qt;
import telar.gui.ui.app.chrome.activity;
import telar.gui.ui.app.chrome.workspaces;
import telar.gui.ui.kit.store;
import telar.gui.application;

export namespace telar::gui::qt {

  // The sidebar: its regions and the width an automatic sidebar fits to.
  //
  // It reads the store, the workspaces it lists and the activity cards it measures. The window
  // pushes the display it lays the sidebar out in and the window whose fonts measure its text;
  // the sidebar asks the window for a width through widthRequested.
  class [[qt::object, qt_qml_named("SidebarController"), qt_qml_uncreatable("Use the window's sidebar")]] SidebarController final : public QObject {
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

    SidebarController(Store& store, WorkspacesController& workspaces, ActivityController& activity, QObject* parent = nullptr);
    ~SidebarController() override = default;
    SidebarController(const SidebarController&) = delete;
    SidebarController& operator=(const SidebarController&) = delete;
    SidebarController(SidebarController&&) = delete;
    SidebarController& operator=(SidebarController&&) = delete;

    void setDisplay(const application::window::DisplayMetrics& display);
    void setWindow(QQuickWindow& window);
    // Fits an automatic sidebar once the active session is ready and a window measures it. It
    // fits once; refit() asks for it again, as a reload of the configuration does.
    void fitWhenReady();
    void refit();
    [[nodiscard]] QVariantMap regions() const;
    // Asks for the width that shows the content whole.
    [[qt::invokable]] void fit();

    [[qt::signal]] void changed();
    // The logical width the sidebar fits its content in.
    [[qt::signal]] void widthRequested(qreal width);

  private:
    [[nodiscard]] float naturalWidth() const;

    Store& store_;
    WorkspacesController& workspaces_;
    ActivityController& activity_;
    application::window::DisplayMetrics display_;
    QPointer<QQuickWindow> window_;
    bool fit_pending_ = true;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("regions", &SidebarController::regions).withNotify(&SidebarController::changed)
    );
  };

}
