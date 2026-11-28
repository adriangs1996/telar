export module telar.gui.ui.app.chrome.components.machine_chrome:machine_chrome_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.wire.vocabulary;

export namespace telar::gui::qt {

  // What the window's machine chrome draws from: the switcher in the top bar, the other machines
  // in the sidebar and every machine's facts in a bar element. Each MachineChromeLayout reads it.
  //
  // It reads the store, the display the window pushes and the window it is drawn in. Activating
  // a machine asks the window to select it through selectRequested, and the switcher asks for the
  // machine picker through pickerRequested.
  class [[qt::object, qt_qml_named("MachineChromeController"), qt_qml_uncreatable("Use the window's machine chrome")]] MachineChromeController final : public QObject {
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

    // The machine the window shows, as the top bar's switcher draws it: its label, its
    // initial and its color, whether its link is up, whether another machine needs the
    // person, and how many machines the window has.
    explicit MachineChromeController(const Store& store, QObject* parent = nullptr);
    ~MachineChromeController() override = default;
    MachineChromeController(const MachineChromeController&) = delete;
    MachineChromeController& operator=(const MachineChromeController&) = delete;
    MachineChromeController(MachineChromeController&&) = delete;
    MachineChromeController& operator=(MachineChromeController&&) = delete;

    void setDisplay(const application::window::DisplayMetrics& display);
    void setWindow(QQuickWindow& window);
    [[nodiscard]] const Store& store() const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] const application::window::DisplayMetrics& display() const noexcept;
    // The window the chrome activates machines in; activations from any other are ignored.
    [[nodiscard]] QQuickWindow* window() const noexcept;
    [[nodiscard]] QVariantMap active() const;
    // A machine's written color in the window's theme; the accent when it names none.
    [[nodiscard]] QColor ink(std::string_view written) const;
    [[nodiscard]] QColor fill(CellColor value) const;
    // What a machine's avatar reads: its label's first character, whole when it is a surrogate pair.
    [[nodiscard]] static QString initial(const QString& label);
    [[qt::invokable]] void pick();
    void select(application::machines::MachineToken token);

    // The display moved, and with it the configuration it measures.
    [[qt::signal]] void changed();
    [[qt::signal]] void machinesChanged();
    [[qt::signal]] void activeChanged();
    [[qt::signal]] void pickerRequested();
    [[qt::signal]] void selectRequested(telar::gui::application::machines::MachineToken token);

  private:
    const Store& store_;
    application::window::DisplayMetrics display_{};
    QPointer<QQuickWindow> window_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("active", &MachineChromeController::active).withNotify(&MachineChromeController::activeChanged)
    );
  };

}
