export module telar.gui.ui.app:window_display;

import telar.gui.qt;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.store;
import telar.gui.foundation.core;
import telar.gui.application;

export namespace telar::gui::qt {

  // The display the window draws in: its size, its density and the cell of its terminal font,
  // and the geometry they give every part of the window, the sidebar among them.
  //
  // It reads the store and the configuration. The window tells it when its size, its screen or
  // its configuration moved; changed() then lets every part measure itself again.
  class [[qt::object, qt_qml_named("WindowDisplay"), qt_qml_uncreatable("Use the window's display")]] WindowDisplay final : public QObject {
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

    // How much the chrome's text has grown over its design size. A dialog scales the lengths
    // that frame its text by it, so the text keeps its room at any font size.
    WindowDisplay(Store& store, ConfigurationSource& configuration, QObject* parent = nullptr);
    ~WindowDisplay() override = default;
    WindowDisplay(const WindowDisplay&) = delete;
    WindowDisplay& operator=(const WindowDisplay&) = delete;
    WindowDisplay(WindowDisplay&&) = delete;
    WindowDisplay& operator=(WindowDisplay&&) = delete;

    void setWindow(QQuickWindow& window);
    // The window's own density, or 1 before it has a window.
    [[nodiscard]] qreal density() const;
    [[nodiscard]] application::window::DisplayMetrics metrics(qreal density) const;
    [[nodiscard]] application::history::HistoryModalMetrics historyMetrics() const;
    [[nodiscard]] const CellMetrics& cell() const noexcept;
    [[nodiscard]] const TerminalGrid& grid() const noexcept;
    [[nodiscard]] ResolvedFont resolveFont(qreal scale);

    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] static qreal chromeRatio();
    [[nodiscard]] qreal chromeTextScale() const;
    [[nodiscard]] qreal chromeTextRatio() const;
    [[nodiscard]] qreal windowControls() const;
    [[nodiscard]] bool sidebarVisible() const;
    [[nodiscard]] qreal sidebarWidth() const;
    [[nodiscard]] bool workspaceListCollapsed() const;
    [[qt::invokable]] void setSidebarWidth(qreal width);

    // Measures the terminal font's cell at the window's density.
    void measureFont();
    // Adopts the window's size, and tells whether it moved.
    bool resize(qreal width, qreal height);
    // Hands every client the workbench its panes are laid out in.
    void layoutWorkbench();
    // The geometry moved: lays the workbench out again and notifies changed().
    void publish();

    // The window was resized, its configuration or its font moved, or the sidebar was shown,
    // hidden, resized or its workspace list folded.
    [[qt::signal]] void changed();

  private:
    static constexpr Viewport default_viewport{.width = 1200, .height = 800, .scale = 1};

    [[nodiscard]] const Configuration& configuration() const noexcept;

    Store& store_;
    ConfigurationSource& configuration_;
    QPointer<QQuickWindow> window_;
    Viewport viewport_ = default_viewport;
    CellMetrics cell_metrics_;
    TerminalGrid terminal_grid_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("geometry", &WindowDisplay::geometry).withNotify(&WindowDisplay::changed),
        telar::qt::property("chromeRatio", &WindowDisplay::chromeRatio).withNotify(&WindowDisplay::changed),
        telar::qt::property("chromeTextScale", &WindowDisplay::chromeTextScale).withNotify(&WindowDisplay::changed),
        telar::qt::property("chromeTextRatio", &WindowDisplay::chromeTextRatio).withNotify(&WindowDisplay::changed),
        telar::qt::property("windowControls", &WindowDisplay::windowControls).withNotify(&WindowDisplay::changed),
        telar::qt::property("sidebarVisible", &WindowDisplay::sidebarVisible).withNotify(&WindowDisplay::changed),
        telar::qt::property("sidebarWidth", &WindowDisplay::sidebarWidth).withNotify(&WindowDisplay::changed),
        telar::qt::property("workspaceListCollapsed", &WindowDisplay::workspaceListCollapsed).withNotify(&WindowDisplay::changed)
    );
  };

}
