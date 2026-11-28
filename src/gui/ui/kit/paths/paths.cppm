export module telar.gui.ui.kit.paths;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;

export namespace telar::gui::qt {

  // The path picker: what is typed, the paths the active session listed for it, which one is
  // selected, and where the picker is drawn, as a dialog under the focused pane's cursor or as
  // rows of its prompt line.
  //
  // It reads the store and the display the window pushes, and asks the session to list, descend
  // and insert. The window opens the picker; inserting a path asks it to close.
  class [[qt::object, qt_qml_named("PathPickerController"), qt_qml_uncreatable("Use the window's path picker")]] PathPickerController final : public QObject {
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

    explicit PathPickerController(Store& store, QObject* parent = nullptr);
    ~PathPickerController() override = default;
    PathPickerController(const PathPickerController&) = delete;
    PathPickerController& operator=(const PathPickerController&) = delete;
    PathPickerController(PathPickerController&&) = delete;
    PathPickerController& operator=(PathPickerController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    // Not const: arranging the layout fills its placements.
    [[nodiscard]] QVariantMap geometry();
    // The paths from `first` on, at most `count`, cut to `columns` cells, for the prompt line's rows.
    [[qt::invokable]] [[nodiscard]] QVariantList rows(int columns, int first, int count) const;
    [[qt::invokable]] void search(const QString& text);
    [[qt::invokable]] void reportQueryLimit(qulonglong requested_bytes);
    [[qt::invokable]] void move(int delta);
    [[qt::invokable]] void descend();
    [[qt::invokable]] void ascend();
    [[qt::invokable]] void insert(bool absolute);
    [[qt::invokable]] void activate(const QVariantMap& choice);

    // Starts listing from the path under the cursor; false when the session cannot.
    bool open();
    // The session listed paths: the selection stays within them.
    void refresh();
    // The workbench or a pane moved under the picker.
    void publishGeometry();
    void setDisplay(const application::window::DisplayMetrics& display);

    [[qt::signal]] void changed();
    [[qt::signal]] void geometryChanged();
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] application::paths::PathPickerPlacement placement();

    // Runs a user's mutation of the session and commits it to the store.
    template <std::invocable Mutation>
    [[tbc::generic]] void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        failed(QString::fromUtf8(error.what()));
      });
    }

    Store& store_;
    QString query_;
    std::size_t selection_ = 0;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &PathPickerController::state).withNotify(&PathPickerController::changed),
        telar::qt::property("geometry", &PathPickerController::geometry).withNotify(&PathPickerController::geometryChanged)
    );
  };

}
