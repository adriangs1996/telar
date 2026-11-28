export module telar.gui.ui.app.overlays.notifications:notifications_controller;

import std;
import telar.gui.qt;
import telar.wire.vocabulary;
import telar.gui.ui.kit.store;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The notifications the active session holds: the cards the overlay stacks over the
  // terminals, when each one fades, and dismissing or acting on one.
  //
  // It reads the store and the display and window the window pushes. Acting on a card opens its
  // link and gives the keyboard back to the terminal, which the window does when the controller
  // asks.
  class [[qt::object, qt_qml_named("NotificationsController"), qt_qml_uncreatable("Use the window's notifications")]] NotificationsController final : public QObject {
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

    explicit NotificationsController(Store& store, QObject* parent = nullptr);
    ~NotificationsController() override = default;
    NotificationsController(const NotificationsController&) = delete;
    NotificationsController& operator=(const NotificationsController&) = delete;
    NotificationsController(NotificationsController&&) = delete;
    NotificationsController& operator=(NotificationsController&&) = delete;

    [[nodiscard]] const application::notifications::NotificationCenter& center() const noexcept;
    // A card's identity in QML, which names the machine view it was shown in.
    [[nodiscard]] QString identity(application::notifications::NotificationId identity) const;
    [[nodiscard]] bool targetVisible(NotificationTarget target) const noexcept;
    // Where the cards stack: the terminal area, cut to whole cells.
    [[nodiscard]] Rect host() const;
    [[nodiscard]] const application::window::DisplayMetrics& display() const noexcept;
    [[nodiscard]] std::uint64_t machineView() const noexcept;

    [[qt::invokable]] void dismiss(const QString& identity);
    [[qt::invokable]] void activate(const QString& identity);
    // The card that held the keyboard is going away: the focused terminal takes it back once
    // nothing else did meanwhile.
    [[qt::invokable]] void retireFocus(const QString& identity, QQuickItem* retiring_owner = nullptr);

    void publish(application::notifications::NotificationInput input);
    // Shows what the session holds now, and when the next card fades.
    void refresh();
    // Refreshes only when the session published or retired a card since the last refresh.
    void present();
    // What the window shows moved: a card's target may have come into view or left it.
    void publishView();
    void setDisplay(const application::window::DisplayMetrics& display, TerminalGrid grid);
    // The window the cards show in, and its generation, which changes with each window.
    void setWindow(QQuickWindow& window, std::uint64_t generation);

    [[qt::signal]] void changed();
    [[qt::signal]] void viewChanged();
    [[qt::signal]] void displayChanged();
    [[qt::signal]] void linkRequested(const QString& uri);
    [[qt::signal]] void focusRestoreRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    [[nodiscard]] ds::Option<application::notifications::NotificationId> resolve(const QString& identity) const;
    void schedule();

    Store& store_;
    QTimer timer_;
    std::uint64_t presented_ = 0;
    application::window::DisplayMetrics display_{};
    TerminalGrid grid_{};
    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
  };

}
