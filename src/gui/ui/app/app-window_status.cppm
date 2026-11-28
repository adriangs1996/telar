export module telar.gui.ui.app:window_status;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.ui.app.panes.terminal;

export namespace telar::gui::qt {

  class KeyBindings;

  // What the window reports about itself: its title, the failure it shows, the TLS proxy badge,
  // whether the active machine's runtime is connected, the mode its keys are in and the active
  // host's metrics.
  //
  // It reads the store, the copy mode and the pending prefix. Whoever changes one of them calls
  // publish(), which notifies only what moved.
  class [[qt::object, qt_qml_named("WindowStatus"), qt_qml_uncreatable("Use the window's status")]] WindowStatus final : public QObject {
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

    WindowStatus(Store& store, CopyController& copy, KeyBindings& keys, QByteArray hostname, QObject* parent = nullptr);
    ~WindowStatus() override = default;
    WindowStatus(const WindowStatus&) = delete;
    WindowStatus& operator=(const WindowStatus&) = delete;
    WindowStatus(WindowStatus&&) = delete;
    WindowStatus& operator=(WindowStatus&&) = delete;

    [[nodiscard]] QString title() const;
    [[nodiscard]] QString error() const;
    [[nodiscard]] QString tlsBadgeColor() const;
    [[nodiscard]] bool connected() const;
    [[nodiscard]] bool prefixPending() const noexcept;
    [[nodiscard]] QVariantMap mode() const;
    [[nodiscard]] QVariantMap hostMetrics() const;

    // Shows a failure that happened outside a dialog that shows its own.
    void report(const QString& message);
    void fail(const std::exception& error);
    // Forgets the window's own failure; the session's stays until it is dismissed.
    void clear();
    [[qt::invokable]] void dismiss();
    // Notifies the title, the diagnostic and the copy mode properties whose value moved since
    // they were last published.
    void publish();
    void publishMetrics();

    [[qt::signal]] void titleChanged();
    // The error, the TLS proxy badge or whether the runtime is connected moved.
    [[qt::signal]] void diagnosticChanged();
    [[qt::signal]] void prefixChanged();
    [[qt::signal]] void modeChanged();
    [[qt::signal]] void hostMetricsChanged();

  private:
    // What the status properties last published, so publish() notifies only what moved.
    struct Published {
      QString title;
      QString error;
      QString tls_badge_color;
      bool connected = false;
    };

    Store& store_;
    CopyController& copy_;
    KeyBindings& keys_;
    QByteArray hostname_;
    QString error_;
    Published published_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("title", &WindowStatus::title).withNotify(&WindowStatus::titleChanged),
        telar::qt::property("error", &WindowStatus::error).withNotify(&WindowStatus::diagnosticChanged),
        telar::qt::property("tlsBadgeColor", &WindowStatus::tlsBadgeColor).withNotify(&WindowStatus::diagnosticChanged),
        telar::qt::property("connected", &WindowStatus::connected).withNotify(&WindowStatus::diagnosticChanged),
        telar::qt::property("prefixPending", &WindowStatus::prefixPending).withNotify(&WindowStatus::prefixChanged),
        telar::qt::property("mode", &WindowStatus::mode).withNotify(&WindowStatus::modeChanged),
        telar::qt::property("hostMetrics", &WindowStatus::hostMetrics).withNotify(&WindowStatus::hostMetricsChanged)
    );
  };

}
