export module telar.gui.ui.app.chrome.workspaces:workspaces_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.base.ds;

export namespace telar::gui::qt {

  // The projects the navigation bar lists, and the workspace the active tab belongs to.
  //
  // It reads the active session in the store. Each synchronize() compares the versions it
  // projected last with the current ones and rebuilds the records only when one moved.
  class [[qt::object, qt_qml_named("WorkspacesController"), qt_qml_uncreatable("Use the window's workspaces")]] WorkspacesController final : public QObject {
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

    explicit WorkspacesController(Store& store, QObject* parent = nullptr);
    ~WorkspacesController() override = default;
    WorkspacesController(const WorkspacesController&) = delete;
    WorkspacesController& operator=(const WorkspacesController&) = delete;
    WorkspacesController(WorkspacesController&&) = delete;
    WorkspacesController& operator=(WorkspacesController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] int count() const noexcept;
    [[nodiscard]] const QVariantMap& context() const noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

    [[qt::signal]] void contextChanged();

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t workspace = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t workspace_list = 0;
      std::uint64_t agents = 0;

      bool operator==(const Inputs&) const = default;
    };

    [[nodiscard]] Inputs inputs() const;

    Store& store_;
    ListModel rows_;
    QVariantMap context_;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("rows", &WorkspacesController::rows).constant(),
        telar::qt::property("context", &WorkspacesController::context).withNotify(&WorkspacesController::contextChanged)
    );
  };

}
