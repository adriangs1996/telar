export module telar.gui.ui.app.panes.terminal:copy_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.gui.foundation.terminal;
import telar.base.ds;

export namespace telar::gui::qt {

  // Copy mode over a pane's scrollback: the keyboard cursor and selection, the pointer's
  // selection, and the search through the scrollback or one command's output.
  //
  // The state lives in the active session; this controller drives it from the keys and the
  // pointer the terminal items deliver, and tells which panes to draw again. The window opens
  // the search line, opens links and shows failures when the controller asks.
  class [[qt::object, qt_qml_named("CopyController"), qt_qml_uncreatable("Use the window's copy mode")]] CopyController final : public QObject {
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

    // The search as it is typed: its query, whether an answer is awaited, how many matches and
    // which one the cursor is on, and what it reads.
    // The command whose output the search reads, empty while it reads the whole scrollback; and
    // whether Tab can switch between the two.
    explicit CopyController(Store& store, QObject* parent = nullptr);
    ~CopyController() override = default;
    CopyController(const CopyController&) = delete;
    CopyController& operator=(const CopyController&) = delete;
    CopyController(CopyController&&) = delete;
    CopyController& operator=(CopyController&&) = delete;

    [[nodiscard]] bool active() const noexcept;
    [[nodiscard]] const ds::Option<application::terminal::copy_mode::CopyState>& state() const noexcept;
    [[nodiscard]] QVariantMap searchState() const;
    [[nodiscard]] QString searchScope() const;
    [[nodiscard]] bool searchScopes() const;

    [[qt::invokable]] void toggleSearchScope();
    [[qt::invokable]] void search(const QString& text);
    [[qt::invokable]] void step(bool forward);
    // The search typed so far stays, its matches for n and N; the line goes back to the editor.
    [[qt::invokable]] void finishSearch();

    // A key for the pane copy mode moves in; false when copy mode does not own it.
    bool handleKey(std::uint64_t pane_id, const QKeyEvent& event);
    // A pointer press, drag, release or wheel; false when copy mode does not own it.
    bool handlePointer(const application::terminal::copy_mode::CopyPointerInput& input);
    bool beginSelection(std::uint64_t pane_id, CopyPoint local);
    void copySelection(std::uint64_t pane_id);
    // Leaves the keyboard's copy mode; a pointer's selection stays.
    void leaveKeyboard();
    // Copy mode moved from the pane it was in: both panes draw again.
    void publishChange(std::uint64_t previous_pane);
    // Notifies whether copy mode is active, when that moved since it last did.
    void publish();
    // The session's search moved, or the search line opened or closed.
    void publishSearch();

    [[qt::signal]] void activeChanged();
    [[qt::signal]] void searchChanged();
    [[qt::signal]] void paneChanged(qulonglong pane_id);
    // A key or a pointer press began: a pending key sequence ends.
    [[qt::signal]] void inputStarted();
    [[qt::signal]] void searchRequested();
    [[qt::signal]] void linkRequested(qulonglong pane_id, telar::gui::CellPosition cursor);
    [[qt::signal]] void closeRequested();
    [[qt::signal]] void failed(const QString& message);

  private:
    [[nodiscard]] bool idle() const noexcept;

    Store& store_;
    QElapsedTimer clock_;
    bool published_active_ = false;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("active", &CopyController::active).withNotify(&CopyController::activeChanged),
        telar::qt::property("searchState", &CopyController::searchState).withNotify(&CopyController::searchChanged),
        telar::qt::property("searchScope", &CopyController::searchScope).withNotify(&CopyController::searchChanged),
        telar::qt::property("searchScopes", &CopyController::searchScopes).withNotify(&CopyController::searchChanged)
    );
  };

}
