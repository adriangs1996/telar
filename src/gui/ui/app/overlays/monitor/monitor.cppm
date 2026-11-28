export module telar.gui.ui.app.overlays.monitor;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.input;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  // The monitor over the window: the active machine's processors, memory, disks, network and
  // every process, which its runtime answers every 2 s while the monitor shows, and the actions on
  // the process selected in it. The process table is laid out in cells of the terminal's font; the
  // controller gives each cell its text, so QML only places it.
  class [[qt::object, qt_qml_named("MonitorController"), qt_qml_uncreatable("Use the window's monitor")]] MonitorController final : public QObject {
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

    static constexpr int refresh_milliseconds = 2000;

    explicit MonitorController(Store& store, QObject* parent = nullptr);
    ~MonitorController() override = default;
    MonitorController(const MonitorController&) = delete;
    MonitorController& operator=(const MonitorController&) = delete;
    MonitorController(MonitorController&&) = delete;
    MonitorController& operator=(MonitorController&&) = delete;

    [[nodiscard]] bool available() const;
    [[nodiscard]] QVariantMap header() const;
    [[nodiscard]] QVariantList machines() const;
    [[nodiscard]] QVariantMap panels() const;
    [[nodiscard]] QVariantMap view() const;
    [[nodiscard]] QVariantList columns() const;
    [[nodiscard]] QVariantMap detail() const;
    [[nodiscard]] QVariantMap footer() const;
    // The row above the table for the CPU no listed process accounts for: the other users' and the
    // kernel's. Empty when the listing is narrowed, or the runtime misses nothing.
    [[nodiscard]] QVariantMap unattributed() const;
    // The action waiting for a yes, and the process it acts on; empty when none waits.
    [[nodiscard]] QVariantMap confirmation() const;
    [[nodiscard]] QString error() const;
    [[nodiscard]] QAbstractItemModel* rows() noexcept;

    // The process table's area and the size of a row's cell of the terminal font: how many rows and
    // cells it shows.
    [[qt::invokable]] void setTable(QSizeF area, QSizeF cell);
    // Moves the rows the table shows by `delta`, keeping the selection.
    [[qt::invokable]] void scroll(int delta);
    // Selects the process `delta` rows from the selected one, and shows it.
    [[qt::invokable]] void move(int delta);
    // Selects the process in the table's row `index`, counted from the first it shows.
    [[qt::invokable]] void selectRow(int index);
    [[qt::invokable]] void clearSelection();
    [[qt::invokable]] void setSort(const QString& sort);
    [[qt::invokable]] void cycleSort();
    [[qt::invokable]] void toggleReverse();
    [[qt::invokable]] void setScope(const QString& scope);
    [[qt::invokable]] void setLayout(const QString& layout);
    [[qt::invokable]] void toggleTree();
    [[qt::invokable]] void setFilter(const QString& filter);
    // Folds the branch of `pid` in the tree, or unfolds it.
    [[qt::invokable]] void toggleFold(int pid);
    // Folds or unfolds the selected process's branch.
    [[qt::invokable]] void foldSelected(bool folded);
    // STOP or CONT to the selected process; TERM and KILL ask first.
    [[qt::invokable]] void signal(const QString& name);
    // TERM, KILL or attaching the debugger to the process selected now, once confirmed. Another
    // selection or machine cancels it.
    [[qt::invokable]] void ask(const QString& action);
    [[qt::invokable]] void confirm();
    [[qt::invokable]] void cancel();
    [[qt::invokable]] void renice(int nice);
    [[qt::invokable]] void copyCommand();
    [[qt::invokable]] void focusPane();
    // Splits the focused pane beside one that runs `telar process review` on the selected process:
    // its stack, files or logs; the debugger asks first.
    [[qt::invokable]] void review(const QString& tool);
    // Shows the machine of the window's list in `slot`, and the monitor with it.
    [[qt::invokable]] void selectMachine(int slot);
    [[qt::invokable]] void close();

    // The monitor shows: ask now, and every 2 s while it shows.
    void opened();
    // The window shows another machine: what the monitor held was the last one's.
    void machineChanged();
    // The session kept a new answer, or what the runtime refused.
    void synchronize();
    // Whether a process is selected, for the actions that act on it.
    [[nodiscard]] bool selected() const;
    // Runs a palette or key binding action on the process selected; false when none is.
    bool perform(window_actions::Action action);

    [[qt::signal]] void changed();
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);
    [[qt::signal]] void filterRequested();
    [[qt::signal]] void machineRequested(application::machines::MachineToken token);

  private:
    enum class Confirmable : std::uint8_t {
      terminate,
      kill,
      debug,
    };

    // An action asked on a process of a machine; it runs on that one or on none.
    struct Confirmation {
      Confirmable action{};
      application::monitor::ProcessInstance process{};
      application::machines::MachineToken machine{};
      // The process as the window named it when it asked.
      QString target;
    };

    void refresh();
    // Asks again at once, for a view that changed.
    void restart();
    [[nodiscard]] bool showing() const;
    // Whether the window shows the machine it runs on: the home and the window's own process are
    // known only there.
    [[nodiscard]] bool local() const;
    // The table's rows from what the session holds.
    void publish();
    // Moves the rows shown so they include `row`.
    void reveal(std::size_t row);
    // Selects the process of the listing's row `row` if the window holds it.
    bool selectAt(std::size_t row);
    // The row of the listing the selected process stands in, if the window holds it.
    [[nodiscard]] ds::Option<std::size_t> selectedRow() const;
    // A cell of the table: the text in the column's cells, cut with `mark`.
    [[nodiscard]] QString cell(application::monitor::Column column, std::string_view value, std::string_view mark = "…") const;
    [[nodiscard]] QVariantMap processRecord(const application::monitor::ProcessRow& row) const;
    [[nodiscard]] QVariantMap groupRecord(const application::monitor::GroupRow& group) const;
    // Whether the process and the machine it was asked on are still the ones selected.
    [[nodiscard]] bool current(const Confirmation& confirmation) const;
    // The program and pid of a process the window holds; its pid alone otherwise.
    [[nodiscard]] QString target(const application::monitor::ProcessInstance& process) const;
    void send(const application::monitor::ProcessInstance& process, application::monitor::ProcessSignal signal);
    void launch(const application::monitor::ProcessInstance& process, const QString& tool);
    // Lowers the selected process's priority one step from the nice value its detail read.
    void lowerPriority();

    Store& store_;
    ListModel rows_;
    QTimer timer_;
    std::uint64_t revision_ = 0;
    application::monitor::Columns columns_{};
    std::uint16_t cells_ = 0;
    qreal cell_width_ = 0;
    // A row the person moved to that the window did not hold yet; selected when it arrives.
    ds::Option<std::size_t> pending_row_;
    ds::Option<Confirmation> confirmation_;
    QString home_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("available", &MonitorController::available).withNotify(&MonitorController::changed),
        telar::qt::property("header", &MonitorController::header).withNotify(&MonitorController::changed),
        telar::qt::property("machines", &MonitorController::machines).withNotify(&MonitorController::changed),
        telar::qt::property("panels", &MonitorController::panels).withNotify(&MonitorController::changed),
        telar::qt::property("view", &MonitorController::view).withNotify(&MonitorController::changed),
        telar::qt::property("columns", &MonitorController::columns).withNotify(&MonitorController::changed),
        telar::qt::property("detail", &MonitorController::detail).withNotify(&MonitorController::changed),
        telar::qt::property("footer", &MonitorController::footer).withNotify(&MonitorController::changed),
        telar::qt::property("unattributed", &MonitorController::unattributed).withNotify(&MonitorController::changed),
        telar::qt::property("confirmation", &MonitorController::confirmation).withNotify(&MonitorController::changed),
        telar::qt::property("error", &MonitorController::error).withNotify(&MonitorController::changed),
        telar::qt::property("rows", &MonitorController::rows).constant()
    );
  };

}
