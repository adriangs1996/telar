export module telar.gui.ui.app.overlays.explorer;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  // The explorer over the panes: the files of a machine as a tree a person moves in with Neovim's
  // keys, edits as text and hands to the panes. Each of its windows is on one of the machines the
  // window keeps, and reads the cache the session of that machine holds. The controller gives
  // each window the rows it shows and nothing past them, so a directory of any size costs what
  // the window draws.
  class [[qt::object, qt_qml_named("ExplorerController"), qt_qml_uncreatable("Use the window's explorer")]] ExplorerController final : public QObject {
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

    explicit ExplorerController(Store& store, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ExplorerController() override = default;
    ExplorerController(const ExplorerController&) = delete;
    ExplorerController& operator=(const ExplorerController&) = delete;
    ExplorerController(ExplorerController&&) = delete;
    ExplorerController& operator=(ExplorerController&&) = delete;

    [[nodiscard]] bool available() const;
    [[nodiscard]] bool showing() const;
    [[nodiscard]] bool sideBySide() const;
    // Whether it stands as a pane of the tab, not over its panes; and whether it takes the keys,
    // which as a pane it does while that pane has the focus.
    [[nodiscard]] bool pinned() const;
    [[nodiscard]] bool focused() const;
    // A key that moves the focus between panes was pressed while the explorer's pane has it: the
    // explorer takes it to go to its window on that side. False when it has none there, and
    // the pane on that side is the one to focus.
    [[nodiscard]] bool takes(application::explorer::Side side);
    // An editor asked for the explorer on a file of the machine that shows: it opens, or the
    // window that has the keys goes, to the file's directory, with the file selected. Without
    // a path, to `directory`.
    void reveal(std::string_view path, std::string_view directory);
    [[nodiscard]] const QVariantList& windows() const noexcept;
    [[nodiscard]] const QVariantList& lenses() const noexcept;
    [[nodiscard]] QString scope() const;
    // The line under the windows: the mode the keys are read in, what the explorer says, and
    // what the mode's field starts with.
    [[nodiscard]] const QVariantMap& line() const noexcept;
    [[nodiscard]] const QVariantList& hints() const noexcept;
    [[nodiscard]] const QVariantMap& preview() const noexcept;
    // The steps of the plan `:w` shows.
    [[nodiscard]] const QVariantList& plan() const noexcept;
    // The menu of a row while one shows: its lines, and where the pointer asked for it.
    [[nodiscard]] const QVariantMap& menu() const noexcept;
    [[nodiscard]] const QVariantList& transfers() const noexcept;
    [[nodiscard]] QVariantList help() const;

    // The rows window `window` shows.
    [[qt::invokable]] QAbstractItemModel* rows(int window);
    // A key the explorer was given; false for one it has no use for.
    [[qt::invokable]] bool key(int key, const QString& text, int modifiers);
    // What was typed in the field of the mode, as it changes and when Enter ends it; and Escape.
    [[qt::invokable]] void typed(const QString& text);
    [[qt::invokable]] void submit(const QString& text);
    [[qt::invokable]] void cancel();
    // `<Tab>` on the command line `text`: what it completes arrives in `line`.
    [[qt::invokable]] void complete(const QString& text);
    // While a filter is typed, the selection moves `rows` rows among what it found.
    [[qt::invokable]] void step(int rows);
    // The pointer on row `row` of a window, counted from the first row of its listing: a click
    // alone on the row that was selected folds or unfolds it, or its diff.
    [[qt::invokable]] void select(int window, int row, bool extend, bool toggle);
    // The pointer chose a directory of the path a window's head shows.
    [[qt::invokable]] void climb(int window, const QString& directory);
    [[qt::invokable]] void activate(int window, int row);
    [[qt::invokable]] void toggleRow(int window, int row);
    // The pointer asked for the menu of a row, at a place of the explorer; a row below zero is
    // the window itself, and a place below zero the selected row's. And chose a line of it.
    [[qt::invokable]] void openMenu(int window, int row, const QPointF& place);
    [[qt::invokable]] void chooseMenu(int line);
    // Whether a row is part of the selection a drag or a menu would take.
    [[nodiscard]] [[qt::invokable]] bool isChosen(int window, int row) const;
    // The pointer took hold of a row to drag it: how many rows go with it. Then where it is
    // would take `count` of them, in the directory at `row` or in the window's root at -1; and
    // it let them go there, or where nothing takes them.
    [[qt::invokable]] int grab(int window, int row);
    // Files dragged in from outside the window: how many the explorer holds to be dropped, none
    // when one of them is no file of this machine.
    [[qt::invokable]] int grabFiles(const QList<QUrl>& urls);
    // `copy` and `move` are what the person holds to ask for one: rows move on their machine and
    // are copied to another unless one of them says otherwise.
    [[nodiscard]] [[qt::invokable]] QVariantMap aim(int window, int row, bool copy, bool move) const;
    [[qt::invokable]] void drop(int window, int row, bool copy, bool move);
    // The rows dragged left `window`: another program takes them from here on, and the explorer
    // holds them no more. A file of another machine is carried to this one for it: once the
    // system asks for it, where it promises files, and a directory the same way, as its tree;
    // or before the rows are given to the system where it promises none, while what is dragged
    // is files and small.
    [[qt::invokable]] void dragOut(QQuickWindow* window);
    // What a program outside the window is given of the rows dragged, or of the ones that last
    // left: a line of text each, the path of a file of the machine the window runs on and
    // `label:/path` of another's; and a file URL of each of the first kind, and of each file of
    // another machine that was carried here first.
    [[nodiscard]] std::unique_ptr<QMimeData> draggedData();
    // What the window makes of a file of another machine that is dragged out, and the directory
    // it keeps those it carries first in: the platform's, unless a test says another.
    void carryOutAs(application::explorer::Outside outside, const QString& cache);

    // The rows that last left as the system's drag has them: a test asks a promise among them
    // for its file, as the system does once the row is let go.
    [[tbc::hot_path]] [[nodiscard]] inline const platform::FileDrag& draggedOut() const noexcept {
      return drag_;
    }

    // Asks a file on its way between two machines to stop.
    [[qt::invokable]] void cancelTransfer(int id);
    [[qt::invokable]] void release();
    // The rows dragged were let go over a pane, which takes them as Enter would give them.
    [[qt::invokable]] void dropOnPane(qulonglong pane);
    // A press in it asks for the keys: as a pane, its pane takes the focus.
    [[qt::invokable]] void claimFocus();
    // The list of a window is `room` tall, in hundredths of one of the design's pixels; the wheel
    // moves what it shows.
    [[qt::invokable]] void setViewport(int window, int room);
    [[qt::invokable]] void scroll(int window, int rows);
    // Types the keys of a hint, as a click on it asks.
    [[qt::invokable]] void type(const QString& keys);
    // Runs a command as the command line would: `tree`, `w`, `e ~/src`.
    [[qt::invokable]] void run(const QString& command);
    // A click on the machine of a window's head: the window goes to the next one, as `gm`.
    [[qt::invokable]] void nextMachine(int window);
    // A click on what a window's status line says it follows: it follows the focused pane, or
    // stays where it is, as `:follow` asks.
    [[qt::invokable]] void toggleFollow(int window);
    [[qt::invokable]] void close();

    // Opens the explorer at the focused pane, or closes the one that shows.
    void toggle();
    // The session kept an answer about its files, or what the panes show moved.
    void synchronize();
    // The machines changed: the explorer closes when the window shows another one, whose panes
    // are others, and reads their names and reach again otherwise.
    void machineChanged();

    [[qt::signal]] void changed();
    // Each part of what the explorer shows says so when it changed, and only then.
    [[qt::signal]] void windowsChanged();
    [[qt::signal]] void lensesChanged();
    [[qt::signal]] void lineChanged();
    [[qt::signal]] void hintsChanged();
    [[qt::signal]] void helpChanged();
    [[qt::signal]] void previewChanged();
    [[qt::signal]] void planChanged();
    [[qt::signal]] void menuChanged();
    [[qt::signal]] void transfersChanged();
    // The explorer opened, and closed: the panes give up the keys, and take them back.
    [[qt::signal]] void opened();
    [[qt::signal]] void closed();
    [[qt::signal]] void failed(const QString& message);
    // Files were opened in an editor of a machine the window does not show: it shows it.
    [[qt::signal]] void machineRequested(application::machines::MachineToken token);

  private:
    // Reads again what the explorer sees around the files: the panes that show, and each
    // machine with its label, its home and whether its runtime answers.
    void observe();
    // The cache of the machine an explorer's window is on: the one its session holds, or one
    // that holds nothing, for a machine the window has no client for.
    [[nodiscard]] const application::explorer::State& cacheOf(std::uint64_t machine) const noexcept;
    // The machine of a window of the explorer; the one the window shows for a window it lacks.
    [[nodiscard]] std::uint64_t machineOf(std::size_t window) const noexcept;
    // Brings the windows of every machine up to date with its cache, and asks each runtime for
    // what they lack. True when what the explorer shows changed.
    bool refresh();
    // Carries the files on their way between machines a step further, on every machine. True
    // when what the explorer shows of them changed.
    bool carry();
    [[nodiscard]] QVariantList describeTransfers(const application::explorer::Around& around) const;
    // The system asked for the file a row of the ones that left promised: it is carried to where
    // the system wants it, which is told how that ended.
    void fetchPromised(const platform::PromisedFile& file);
    // Gives the rows that left to the system's drag, the files of another machine among them
    // as promises.
    void promiseOut(QQuickWindow& window, const QStringList& lines);
    // Starts to carry the rows `rows` of the ones that left to a directory of the cache. False
    // when none starts.
    bool fetchFirst(std::span<const std::size_t> rows);
    // Tells the system of the promised files that ended, and gives it the rows that waited for
    // their files once none is on its way.
    void settleOut();
    // The rows that waited for their files were let go before the system had them.
    void abandonOut();
    // Gives the rows that left to Qt's drag, as what `draggedData` says they are.
    void beginDrag();
    // A key a chord names, given to the explorer; false for one it has no use for.
    bool strike(int key, const QString& text, int modifiers);
    // What a use case asks of the panes and of the runtimes, done; and what it asks of the
    // window once it returns.
    void finish(const application::explorer::Action& action);
    void finish(application::explorer::Effect effect);
    // What the explorer shows, from what the session holds: each part is told only when it is
    // another than the one shown.
    void publish();
    [[nodiscard]] QVariantList describeWindows(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantList describeLenses(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantMap describeLine() const;
    [[nodiscard]] QVariantList describeHints(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantMap describePreview(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantList describePlan(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantMap describeMenu(const application::explorer::Around& around) const;
    [[nodiscard]] QVariantMap record(const application::explorer::State& cache, const application::explorer::Context& context, application::explorer::Pick pick) const;

    Store& store_;
    application::explorer::View view_;
    ds::Array<ListModel, 3> rows_;
    QVariantList windows_;
    QVariantList lenses_;
    QVariantMap line_;
    QVariantList hints_;
    QVariantMap preview_;
    QVariantList plan_;
    QVariantMap menu_;
    QVariantList transfers_;
    // Runs while a file is on its way between two machines: its rate is told again, and one
    // that ended leaves the list in a while.
    QTimer transfers_tick_;

    // A file the system asked for, or one a drag waits for: its transfer, the ticket that tells
    // the system how it ended, and where it arrives.
    struct Awaited {
      std::uint32_t transfer = 0;
      std::uint64_t ticket = 0;
      QString path;
    };

    // The rows that last left, as the system's drag has them, with the files they promise.
    platform::FileDrag drag_;
    ds::Vec<Awaited, Memory> promised_;
    ds::Vec<Awaited, Memory> waited_;
    // Whether the rows that left wait for their files before the system's drag has them, and
    // the files that arrived for them.
    bool leaving_ = false;
    QList<QUrl> fetched_;
    application::explorer::Outside outside_;
    QString drag_cache_;
    // Where the pointer asked for the menu; below zero when the keys did.
    QPointF menu_at_{-1, -1};
    std::uint64_t revision_ = 0;
    // What the scene counted of the files the editors hold when the rows were last told.
    std::uint64_t edited_ = 0;

    // Shows the explorer as it now is; with `opening`, it says it opened.
    void present(bool opening);
    // Brings it to where the tab that shows has it: as its pane, or closed when it stood as a
    // pane that is gone or shows no more. True when it closed.
    bool settle();
    // The home of the account the window runs as, which the local machine has before its
    // runtime says it.
    QByteArray home_;
    // What the use cases read around the files, and the cache of a machine that is away: one
    // that holds nothing.
    application::explorer::Scene scene_;
    application::explorer::State away_;
    // The machine the window showed when the explorer last looked.
    application::machines::Machines::Slot shown_ = application::machines::Machines::local_slot;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("available", &ExplorerController::available).withNotify(&ExplorerController::changed),
        telar::qt::property("showing", &ExplorerController::showing).withNotify(&ExplorerController::changed),
        telar::qt::property("sideBySide", &ExplorerController::sideBySide).withNotify(&ExplorerController::changed),
        telar::qt::property("pinned", &ExplorerController::pinned).withNotify(&ExplorerController::changed),
        telar::qt::property("focused", &ExplorerController::focused).withNotify(&ExplorerController::changed),
        telar::qt::property("windows", &ExplorerController::windows).withNotify(&ExplorerController::windowsChanged),
        telar::qt::property("lenses", &ExplorerController::lenses).withNotify(&ExplorerController::lensesChanged),
        telar::qt::property("scope", &ExplorerController::scope).withNotify(&ExplorerController::changed),
        telar::qt::property("line", &ExplorerController::line).withNotify(&ExplorerController::lineChanged),
        telar::qt::property("hints", &ExplorerController::hints).withNotify(&ExplorerController::hintsChanged),
        telar::qt::property("preview", &ExplorerController::preview).withNotify(&ExplorerController::previewChanged),
        telar::qt::property("plan", &ExplorerController::plan).withNotify(&ExplorerController::planChanged),
        telar::qt::property("menu", &ExplorerController::menu).withNotify(&ExplorerController::menuChanged),
        telar::qt::property("transfers", &ExplorerController::transfers).withNotify(&ExplorerController::transfersChanged),
        telar::qt::property("help", &ExplorerController::help).withNotify(&ExplorerController::helpChanged)
    );
  };

}
