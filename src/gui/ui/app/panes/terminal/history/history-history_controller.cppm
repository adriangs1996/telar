export module telar.gui.ui.app.panes.terminal.history:history_controller;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.input;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;
import telar.base.memory.allocators;

extern "C++" namespace telar::gui::test {
  struct HistoryPresentation;
}

export namespace telar::gui::qt {

  // The command history dialog: its rows, search, filters, inspection and pointer targets.
  //
  // It reads the store and never the window that owns it. After each flush of the store it
  // compares the versions it presented last with the current ones, and only then rebuilds what
  // QML reads. Its actions mutate the active session and commit them to the store; the window
  // learns about them from the store and from closeRequested().
  class [[qt::object, qt_qml_named("HistoryController"), qt_qml_uncreatable("Use the window's history"), qt_classinfo("RegisterEnumClassesUnscoped", "false")]] HistoryController final : public QObject {
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

    // QML names every enum value with its enum, as ApplicationController does.
    enum class [[qt::qenum]] Action : quint8 {
      copy,
      erase,
      visit,
      inspect,
      older,
      newer,
    };

    // The choice a frame showed, so that an action from the pointer applies to what was seen.
    struct Presented {
      application::history::HistoryChoice choice;
      std::uint64_t dialog_generation = 0;
      bool enter_runs = false;
    };

    struct HoverFrame {
      ds::Array<application::history::HistoryHoverTarget, application::history::HistoryLimits::page_entries + application::history::HistoryActions::count + application::history::HistoryFooter::capacity + application::history::history_filter_target_count + application::history::history_inspection_action_count> targets;
      std::size_t count = 0;
      std::uint64_t generation = 0;
      double scale = 1;

      [[tbc::hot_path]] inline void append(application::history::HistoryHoverTarget target) {
        if (count < targets.size() && !target.bounds.empty()) {
          targets.atMut(count++) = target;
        }
      }

      [[tbc::hot_path]] [[nodiscard]] inline std::span<const application::history::HistoryHoverTarget> view() const noexcept {
        return std::span{targets}.first(count);
      }
    };

    // What the dialog contributes to one prepared frame.
    struct Frame {
      ds::Option<Presented> history;
      application::history::HistoryScrollSurface surface;
      application::history::HistoryActionSurface actions;
      ds::Option<HoverFrame> hover;
    };

    explicit HistoryController(Store& store, QObject* parent = nullptr);
    ~HistoryController() override = default;
    HistoryController(const HistoryController&) = delete;
    HistoryController& operator=(const HistoryController&) = delete;
    HistoryController(HistoryController&&) = delete;
    HistoryController& operator=(HistoryController&&) = delete;

    // The window shows the dialog: filters start from the configuration and the search from the
    // command the prompt line holds, if it hosts the search.
    void open();
    // The dialog or the window changed: what an earlier frame presented no longer applies.
    void retire();
    // The active session is about to change: nothing the dialog holds belongs to the next one.
    void forget();
    void setWindow(QQuickWindow* window);
    void setMetrics(const application::history::HistoryModalMetrics& metrics);
    // Rebuilds what QML reads when an input it depends on moved since the last call. The window
    // calls it on every flush of the store, in the order its projections depend on each other.
    void synchronize();
    // Reports a failure in the dialog while it is open, and to the window otherwise.
    void fail(const std::exception& error);
    // Runs while the GUI thread is blocked in the scene graph's synchronization.
    void prepare(Frame& frame) const;
    void present(const Frame& frame);
    [[nodiscard]] const application::history::HistoryActionSurface& presentedActions() const noexcept;
    // Whether the focused pane's prompt line hosts the search and scrolls its own rows.
    [[nodiscard]] bool hosted() const;
    bool handleWheel(QWheelEvent& event);
    void scroll(application::history::HistoryScrollPosition pointer, ScrollSample sample);
    void activate(application::history::HistoryCardAction action, application::history::HistoryChoice choice);
    void observeHover(QPointF position, application::history::HistoryHover::Observation observation);
    void retireHover();

    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] bool loading() const;
    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] QString command() const;
    [[nodiscard]] QString output() const;
    [[nodiscard]] QVariantMap inspection() const;
    [[nodiscard]] int hoveredRow() const;
    [[nodiscard]] QString hoveredRowRevision() const;
    [[nodiscard]] QString hoveredCardAction() const;
    [[nodiscard]] QString hoveredFilterAction() const;
    [[nodiscard]] QString hoveredInspectionAction() const;
    [[nodiscard]] int hoveredInspectionIndex() const;
    [[nodiscard]] QString hoveredInspectionRevision() const;
    [[nodiscard]] QString hoveredFooterAction() const;
    [[nodiscard]] int hoveredFooterIndex() const;
    [[nodiscard]] QString hoveredFooterRevision() const;

    // Uses row `row`; while the search is pending or loading, the best match of what was typed
    // once its page arrives, unless typing or moving comes first.
    [[qt::invokable]] void use(int row, bool alternate = false);
    [[qt::invokable]] void usePresented(const QString& revision, bool alternate = false);
    [[qt::invokable]] void execute(Action action, const QString& entry_id = {});
    [[qt::invokable]] void select(int row);
    [[qt::invokable]] void selectPresented(int row, const QString& revision);
    [[qt::invokable]] void search(const QString& query);
    [[qt::invokable]] void setFilters(const QVariantMap& filters);
    [[qt::invokable]] void reportQueryLimit(qulonglong requested_bytes);
    [[qt::invokable]] void registerPanel(QQuickItem* panel);
    [[qt::invokable]] void registerInspector(QQuickItem* inspector);
    [[qt::invokable]] void registerFilters(QQuickItem* filters);
    [[qt::invokable]] void registerFooter(QQuickItem* footer);
    [[qt::invokable]] void registerActions(QQuickItem* actions);

    [[qt::signal]] void changed();
    [[qt::signal]] void hoverChanged();
    [[qt::signal]] void inspectionScrolled(int lines);
    // A command from the dialog went to the prompt; closeRequested() follows.
    [[qt::signal]] void submitted();
    // The dialog finished its work, by pasting a command or by visiting its pane. It is emitted
    // inside the interaction, before the store commits it.
    [[qt::signal]] void closeRequested();
    // A failure outside the open dialog, such as a debounced search that could not be sent; the
    // window shows it.
    [[qt::signal]] void failed(const QString& message);

  private:
    friend struct test::HistoryPresentation;

    // Every input the cached state depends on; a flush that moves none of them rebuilds nothing.
    struct Inputs {
      bool open = false;
      std::uint64_t generation = 0;
      std::uint64_t view_version = 0;
      std::uint64_t search_version = 0;
      std::uint64_t configuration = 0;
      bool loading = false;
      bool pane_open = false;
      QString scope_value;
      BoundedText<TabCaption::capacity> tab_name;

      [[tbc::hot_path]] [[nodiscard]] inline bool operator==(const Inputs& other) const noexcept {
        return open == other.open && generation == other.generation && view_version == other.view_version && search_version == other.search_version && configuration == other.configuration && loading == other.loading && pane_open == other.pane_open && scope_value == other.scope_value && tab_name.view() == other.tab_name.view();
      }
    };

    [[nodiscard]] Inputs inputs();
    [[nodiscard]] QVariantMap buildState() const;
    [[nodiscard]] QVariantMap buildInspection() const;
    void buildRows();
    [[nodiscard]] QString scopeValue();
    [[nodiscard]] std::string_view tabName(const application::Pane<Memory>* pane) const;
    [[nodiscard]] bool isOpen() const noexcept;
    // Whether a search is pending or loading now; actions refuse to run while it is.
    [[nodiscard]] bool busy() const;
    [[nodiscard]] const Presented* presented(const QString& revision) const;
    [[nodiscard]] application::history::HistoryActionSurface actionSurface() const;
    [[nodiscard]] application::history::HistoryScrollSurface scrollSurface(HoverFrame& hover) const;
    void submit(std::uint64_t entry_id, bool alternate);
    void moveRows(std::int32_t steps);
    void notifyHover();
    void query();
    void age();

    // Runs a user's mutation of the session and commits it to the store; a failure shows in the
    // dialog instead.
    template <std::invocable Mutation>
    [[tbc::generic]] void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        fail(error);
      });
    }

    Store& store_;
    ListModel rows_;
    QTimer search_timer_;
    // While the dialog is open, ages move on and a running command's row is read again.
    QTimer age_timer_;
    // Enter pressed while the search loaded, with its alternate flag: it runs the first row of
    // the page that arrives.
    ds::Option<bool> pending_submit_;
    QString query_;
    application::history::HistoryFilters filters_;
    std::uint64_t search_version_ = 0;
    CalendarSample calendar_;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rows_version_ = 0;
    QVariantMap state_;
    QVariantMap inspection_;
    QString command_;
    QString output_;
    QByteArray directory_source_;
    QString directory_value_;
    application::history::HistoryModalMetrics metrics_;
    QPointer<QQuickWindow> window_;
    application::history::HistoryScroll scroll_;
    ScrollEventSequence wheel_sequence_;
    QPointer<QQuickItem> panel_;
    QPointer<QQuickItem> viewport_;
    QPointer<QQuickItem> content_;
    QPointer<QQuickItem> search_host_;
    QPointer<QQuickItem> actions_;
    QPointer<QQuickItem> footer_;
    QPointer<QQuickItem> filter_layout_;
    QPointer<QQuickItem> inspector_;
    ds::Option<Presented> presented_;
    application::history::HistoryScrollSurface presented_surface_;
    application::history::HistoryActionSurface presented_actions_;
    ds::Option<HoverFrame> presented_hover_;
    application::history::HistoryHover hover_;
    ds::Option<std::uint64_t> hover_revision_value_;
    QString hover_revision_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("rows", &HistoryController::rows).constant(),
        telar::qt::property("loading", &HistoryController::loading).withNotify(&HistoryController::changed),
        telar::qt::property("state", &HistoryController::state).withNotify(&HistoryController::changed),
        telar::qt::property("geometry", &HistoryController::geometry).withNotify(&HistoryController::changed),
        telar::qt::property("command", &HistoryController::command).withNotify(&HistoryController::changed),
        telar::qt::property("output", &HistoryController::output).withNotify(&HistoryController::changed),
        telar::qt::property("inspection", &HistoryController::inspection).withNotify(&HistoryController::changed),
        telar::qt::property("hoveredRow", &HistoryController::hoveredRow).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredRowRevision", &HistoryController::hoveredRowRevision).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredCardAction", &HistoryController::hoveredCardAction).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredFilterAction", &HistoryController::hoveredFilterAction).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredInspectionAction", &HistoryController::hoveredInspectionAction).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredInspectionIndex", &HistoryController::hoveredInspectionIndex).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredInspectionRevision", &HistoryController::hoveredInspectionRevision).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredFooterAction", &HistoryController::hoveredFooterAction).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredFooterIndex", &HistoryController::hoveredFooterIndex).withNotify(&HistoryController::hoverChanged),
        telar::qt::property("hoveredFooterRevision", &HistoryController::hoveredFooterRevision).withNotify(&HistoryController::hoverChanged)
    );
  };

}
