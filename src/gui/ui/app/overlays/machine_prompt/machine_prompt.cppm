export module telar.gui.ui.app.overlays.machine_prompt;

import std;
import telar.gui.qt;
import telar.gui.ui.app.overlays.machine_prompt.machine_profiles_source;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The prompt that renames a machine; the machine wizard adds them.
  //
  // It reads the store and the display the window pushes, and writes the machine profiles. The
  // window opens the prompt; submitting it asks it to close.
  class [[qt::object, qt_qml_named("MachinePromptController"), qt_qml_uncreatable("Use the window's machine prompt")]] MachinePromptController final : public QObject {
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

    MachinePromptController(Store& store, MachineProfilesSource& profiles, QObject* parent = nullptr);
    ~MachinePromptController() override = default;
    MachinePromptController(const MachinePromptController&) = delete;
    MachinePromptController& operator=(const MachinePromptController&) = delete;
    MachinePromptController(MachinePromptController&&) = delete;
    MachinePromptController& operator=(MachinePromptController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    [[qt::invokable]] void search(const QString& text);
    [[qt::invokable]] void submit(const QString& revision);
    [[qt::invokable]] void reportLimit(qulonglong requested_bytes);

    // Starts renaming a machine; false when it cannot be renamed.
    bool open(application::machines::MachineToken renamed);
    // The dialog closed: nothing typed belongs to the next prompt.
    void forget() noexcept;
    void setDisplay(const application::window::DisplayMetrics& display);

    [[qt::signal]] void changed();
    [[qt::signal]] void closeRequested();

  private:
    struct Prompt {
      QString text;
      application::machines::MachineToken renamed;
    };

    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] static std::size_t limit() noexcept;

    Store& store_;
    MachineProfilesSource& profiles_;
    ds::Option<Prompt> prompt_;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &MachinePromptController::state).withNotify(&MachinePromptController::changed),
        telar::qt::property("geometry", &MachinePromptController::geometry).withNotify(&MachinePromptController::changed)
    );
  };

}
