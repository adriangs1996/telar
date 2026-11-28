export module telar.gui.ui.app.overlays.workspace_form;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.foundation.system;

export namespace telar::gui::qt {

  // The new workspace form: the folders that complete what is typed in its directory field, which
  // one is selected, and whether submitting will create a missing folder.
  //
  // Folders are listed only on this computer, one listing at a time on a worker; the query typed
  // meanwhile starts once the running one lands. It reads the store and creates the workspace in
  // the active session; the window opens and closes the form.
  class [[qt::object, qt_qml_named("WorkspaceFormController"), qt_qml_uncreatable("Use the window's workspace form")]] WorkspaceFormController final : public QObject {
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

    explicit WorkspaceFormController(Store& store, QObject* parent = nullptr);
    ~WorkspaceFormController() override = default;
    WorkspaceFormController(const WorkspaceFormController&) = delete;
    WorkspaceFormController& operator=(const WorkspaceFormController&) = delete;
    WorkspaceFormController(WorkspaceFormController&&) = delete;
    WorkspaceFormController& operator=(WorkspaceFormController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[qt::invokable]] void edit(const QString& text);
    [[qt::invokable]] void move(int delta);
    // The selected folder joined to what was typed, or empty when none is listed.
    [[qt::invokable]] QString accept();
    [[qt::invokable]] QString choose(int index);

    // The form opened or closed: nothing typed or listed belongs to the next one.
    void reset();
    // Creates the workspace, named after its folder when the name is empty, and asks once before
    // creating a folder that does not exist. False keeps the form open; it throws what the
    // session rejects.
    bool submit(const QVariantMap& input);

    [[qt::signal]] void changed();

  private:
    [[nodiscard]] bool isOpen() const noexcept;
    [[nodiscard]] bool local() const noexcept;
    [[nodiscard]] bool listingCurrent() const;
    [[nodiscard]] QString expand(const QString& text) const;
    void list();
    void land();

    Store& store_;
    QString wanted_;
    QString listing_;
    QString landed_;
    DirectoryCompletion completion_;
    std::size_t selection_ = 0;
    bool confirm_create_ = false;
    QFutureWatcher<DirectoryCompletion> lister_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &WorkspaceFormController::state).withNotify(&WorkspaceFormController::changed)
    );
  };

}
