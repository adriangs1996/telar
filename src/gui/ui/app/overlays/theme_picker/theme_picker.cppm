export module telar.gui.ui.app.overlays.theme_picker;

import std;
import telar.gui.qt;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.tbc;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.process.surface_command;

export namespace telar::gui::qt {

  // The theme picker over the window: one slice per theme, the configuration's first. The window
  // shows the focused theme while the picker is open; choosing one saves it for every window and
  // runs `client.theme_picker.on_select`, and leaving puts back the theme the window had.
  class [[qt::object, qt_qml_named("ThemePickerController"), qt_qml_uncreatable("Use the window's theme picker")]] ThemePickerController final : public QObject {
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

    explicit ThemePickerController(ConfigurationSource& source, QObject* parent = nullptr);
    ~ThemePickerController() override = default;
    ThemePickerController(const ThemePickerController&) = delete;
    ThemePickerController& operator=(const ThemePickerController&) = delete;
    ThemePickerController(ThemePickerController&&) = delete;
    ThemePickerController& operator=(ThemePickerController&&) = delete;

    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] QVariantList themes() const;
    [[nodiscard]] int focus() const noexcept;

    // Lists the themes with the window's own focused.
    void open();
    // Another dialog took the picker's place: the window shows its theme again.
    void dismiss();

    [[qt::invokable]] void focusTheme(int index);
    [[qt::invokable]] void move(int delta);
    // Focuses the first theme whose name starts with what was typed in the last moment.
    [[qt::invokable]] void type(const QString& text);
    [[qt::invokable]] void choose();
    [[qt::invokable]] void cancel();

    [[qt::signal]] void changed();
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    // The configuration's slot leads the list; each theme of the catalog follows it.
    static constexpr int configuration_slot = 0;

    void close();
    void preview();
    void runOnSelect(const QByteArray& name);
    [[nodiscard]] ds::Option<ThemeValues> focusedValues() const;

    ConfigurationSource& source_;
    tbc::val_self<SurfaceCommand> on_select_;
    // The names of the themes, in the order the slices show them after the configuration's.
    QList<QByteArray> names_;
    QVariantList themes_;
    QString typed_;
    qint64 typed_at_ = 0;
    int focus_ = configuration_slot;
    bool open_ = false;
    bool preview_pending_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("open", &ThemePickerController::isOpen).withNotify(&ThemePickerController::changed),
        telar::qt::property("themes", &ThemePickerController::themes).withNotify(&ThemePickerController::changed),
        telar::qt::property("focus", &ThemePickerController::focus).withNotify(&ThemePickerController::changed)
    );
  };

}
