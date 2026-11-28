export module telar.gui.ui.app.overlays.palette;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.machines;
import telar.gui.ui.kit.store;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.gui.foundation.text;
import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  // A window action a palette row runs, by its value: the window's action enum is declared by the
  // window, which reads this controller.
  struct PaletteAction {
    int value = 0;
  };

  // The last row of a search over every kind: it opens the suggestion with the query as its task.
  struct PaletteAsk {
    friend bool operator==(PaletteAsk, PaletteAsk) = default;
  };

  using PaletteTarget = std::variant<NavigationTarget, PaletteAction, application::machines::MachinePickerTarget, PaletteAsk>;

  // The command palette: its query, the rows it matches among the active session's contexts, tabs
  // and agents, the window's actions and the machines, which row is selected, and where each is
  // drawn. A query without a prefix searches every kind at once, grouped by kind; a prefix narrows
  // it to one. The command suggestion is one of its modes and shares its query, and the actions
  // palette it was opened from.
  //
  // It reads the store and the display and commands the window pushes. A row that names a
  // context, a tab or an agent navigates the session, and the suggestion action's row opens the
  // suggestion over it; any other action and the machines are the window's, which it asks to run
  // them. It asks the window to show its dialog again when it changes mode in place, and to close
  // it once a row navigated or a suggestion was submitted.
  class [[qt::object, qt_qml_named("PaletteController"), qt_qml_uncreatable("Use the window's palette")]] PaletteController final : public QObject {
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

    struct EditorPosition {
      int anchor = 0;
      int cursor = 0;
      std::uint64_t revision = 0;
    };

    // The actions palette a suggestion was opened from, to return to it as it was.
    struct Parent {
      QString query;
      std::size_t selection = 0;
      EditorPosition editor;
    };

    struct Choice {
      PaletteTarget target;
      std::size_t index = 0;
    };

    // `suggestion` is the window's action whose row opens the suggestion from the actions palette.
    PaletteController(Store& store, PaletteAction suggestion, QObject* parent = nullptr);
    ~PaletteController() override = default;
    PaletteController(const PaletteController&) = delete;
    PaletteController& operator=(const PaletteController&) = delete;
    PaletteController(PaletteController&&) = delete;
    PaletteController& operator=(PaletteController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] QVariantMap suggestion() const;
    [[nodiscard]] QVariantMap suggestionGeometry() const;

    [[qt::invokable]] void search(const QString& text);
    [[qt::invokable]] void move(int delta);
    [[qt::invokable]] void reportQueryLimit(qulonglong requested_bytes);
    // Uses the row a choice from QML names, while it is the one the palette shows.
    [[qt::invokable]] void activate(const QVariantMap& choice);
    // Submits the suggestion's task while the suggestion the view shows is the current one.
    [[qt::invokable]] void submitSuggestion(const QString& revision);

    // Starts the palette in a mode, with an empty query; the window shows its dialog.
    void open(application::palette::PaletteMode mode);
    // Matches the query again while the palette is open, and notifies when the rows moved.
    void synchronize();
    // The machines moved: a machine query, which starts with ':', matches them again.
    void refreshMachines();
    // Notifies a change of the session the suggestion reads.
    void publish();
    // The dialog closed: no actions palette waits to be returned to.
    void forget() noexcept;
    // The display and the window's actions, as the window measures and binds them.
    void setDisplay(const application::window::DisplayMetrics& display);
    void setCommands(QVariantList commands);

    [[nodiscard]] application::palette::PaletteMode mode() const;
    [[nodiscard]] const QString& query() const noexcept;
    [[nodiscard]] ds::Option<application::machines::MachinePickerTarget> chosenMachine(const QVariantMap& choice) const;
    // Returns to the actions palette the suggestion was opened from; false when the palette is
    // closed or was not opened from one.
    bool restoreParent();
    // The suggestion's revision, which a submission names.
    [[nodiscard]] QString suggestionRevision() const;
    // How many times the rows were matched again and moved, for tests and probes that check what
    // a change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

    [[qt::signal]] void changed();
    // The palette changed mode in place: the window shows its dialog again.
    [[qt::signal]] void showRequested();
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);
    // A row named a machine or one of the window's actions, which the window runs.
    [[qt::signal]] void machineRequested(telar::gui::application::machines::MachinePickerTarget target, bool alternate);
    [[qt::signal]] void actionRequested(telar::gui::qt::PaletteAction action);

  private:
    // Every row a search over all kinds can hold, the suggestion row included.
    static constexpr std::size_t capacity = WorkspaceReplica<Memory>::maximum_workspaces + GuiSession::maximum_workspace_tabs + AgentReplica<Memory>::capacity + application::palette::palette_actions.size() + application::machines::Machines::capacity + 1;
    // A query shorter than this never ranks a destructive action above another match.
    static constexpr std::size_t destructive_query_bytes = 3;
    using Matches = RankedMatches<PaletteTarget, capacity>;

    [[nodiscard]] bool isOpen() const noexcept;
    bool updateResults();
    bool updateMachineResults(std::string_view query);
    void collectNavigation(Matches& matches, std::string_view query) const;
    void collectActions(Matches& matches, std::string_view query) const;
    void collectMachines(Matches& matches, std::string_view query) const;
    [[nodiscard]] QVariantMap record(const PaletteTarget& target, std::string_view query) const;
    [[nodiscard]] QVariantMap machineRecord(application::machines::MachinePickerTarget target) const;
    // The row a choice from QML names, while it is the one the palette shows.
    [[nodiscard]] ds::Option<Choice> chosen(const QVariantMap& choice) const;
    // The actions palette as it is, to return to from the suggestion opened from its row.
    [[nodiscard]] Parent parentFor(const QVariantMap& choice, std::size_t index) const;
    void adoptParent(Parent parent);
    // Selects the context or tab, or focuses the agent; false when the session no longer has it.
    bool navigate(const NavigationTarget& target);

    // Runs a user's mutation of the session and commits it to the store.
    template <std::invocable Mutation>
    [[tbc::generic]] void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        failed(QString::fromUtf8(error.what()));
      });
    }

    Store& store_;
    PaletteAction suggestion_;
    QString query_;
    ds::Option<Parent> parent_;
    EditorPosition editor_restore_;
    QVariantList rows_;
    QVariantList commands_;
    ds::Array<PaletteTarget, capacity> targets_{};
    ds::Array<application::palette::PaletteRowKind, capacity> kinds_{};
    std::size_t selection_ = 0;
    std::uint64_t revision_ = 0;
    std::uint64_t rebuilds_ = 0;
    application::window::DisplayMetrics display_{};

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("state", &PaletteController::state).withNotify(&PaletteController::changed),
        telar::qt::property("geometry", &PaletteController::geometry).withNotify(&PaletteController::changed),
        telar::qt::property("suggestion", &PaletteController::suggestion).withNotify(&PaletteController::changed),
        telar::qt::property("suggestionGeometry", &PaletteController::suggestionGeometry).withNotify(&PaletteController::changed)
    );
  };

}
