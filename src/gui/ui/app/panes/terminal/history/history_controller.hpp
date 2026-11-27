#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/input/scroll_event.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QWheelEvent>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <span>

#pragma once

import telar.gui.application;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::test {
  struct HistoryPresentation;
}

namespace telar::gui::qt {

  // The command history dialog: its rows, search, filters, inspection and pointer targets.
  //
  // It reads the store and never the window that owns it. After each flush of the store it
  // compares the versions it presented last with the current ones, and only then rebuilds what
  // QML reads. Its actions mutate the active session and commit them to the store; the window
  // learns about them from the store and from closeRequested().
  class HistoryController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(HistoryController)
    QML_UNCREATABLE("Use the window's history")
    // QML names every enum value with its enum, as ApplicationController does.
    Q_CLASSINFO("RegisterEnumClassesUnscoped", "false")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)
    Q_PROPERTY(bool loading READ loading NOTIFY changed)
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)
    Q_PROPERTY(QString command READ command NOTIFY changed)
    Q_PROPERTY(QString output READ output NOTIFY changed)
    Q_PROPERTY(QVariantMap inspection READ inspection NOTIFY changed)
    Q_PROPERTY(int hoveredRow READ hoveredRow NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredRowRevision READ hoveredRowRevision NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredCardAction READ hoveredCardAction NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredFilterAction READ hoveredFilterAction NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredInspectionAction READ hoveredInspectionAction NOTIFY hoverChanged)
    Q_PROPERTY(int hoveredInspectionIndex READ hoveredInspectionIndex NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredInspectionRevision READ hoveredInspectionRevision NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredFooterAction READ hoveredFooterAction NOTIFY hoverChanged)
    Q_PROPERTY(int hoveredFooterIndex READ hoveredFooterIndex NOTIFY hoverChanged)
    Q_PROPERTY(QString hoveredFooterRevision READ hoveredFooterRevision NOTIFY hoverChanged)

  public:
    enum class Action : quint8 {
      copy,
      erase,
      visit,
      inspect,
      older,
      newer,
      // Marks or unmarks the command to be used with the others marked.
      mark,
      // Changes the focused shell to the command's directory, or opens a pane there.
      enter,
      open,
      // Takes the last delete back while its notice shows.
      undo,
      // Pins the command to the top of the panel, or unpins it.
      pin,
    };
    Q_ENUM(Action)

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

      void append(application::history::HistoryHoverTarget target) {
        if (count < targets.size() && !target.bounds.empty()) {
          targets.atMut(count++) = target;
        }
      }

      [[nodiscard]] std::span<const application::history::HistoryHoverTarget> view() const noexcept {
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
    // Keeps the pins in the private file at `path`, read now; no path keeps them for the window's
    // life alone.
    void setPinsPath(const QString& path);
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

    // Uses row `row`; while the search is pending or a page loads, the row selected once its page
    // arrives (the best match of what was typed, as fzf runs it), unless typing comes first.
    Q_INVOKABLE void use(int row, bool alternate = false);
    // Moves the selection `delta` rows, positive to older commands, across pages. Moves while the
    // rows shown are about to be replaced apply to the rows that replace them.
    Q_INVOKABLE void move(int delta);
    Q_INVOKABLE void usePresented(const QString& revision, bool alternate = false);
    Q_INVOKABLE void execute(Action action, const QString& entry_id = {});
    // `command` on one line in runs, each {text, marked}, the bytes `ranges` gives (start, end,
    // start…, as a row's record holds what the runtime matched) marked, as the dialog's rows
    // mark them. Newlines show as ↵ and the line stops after a few hundred characters.
    Q_INVOKABLE [[nodiscard]] QVariantList marked(const QString& command, const QVariantList& ranges) const;
    // A row's excerpt of the output in the same runs, from a little before its first match, short
    // enough to sit beside the command.
    Q_INVOKABLE [[nodiscard]] QVariantList excerpt(const QString& text, const QVariantList& ranges) const;
    // Turns a way of listing on or off, as its chip would: "sort" between rank and time, "output"
    // to search what the commands printed, "raw" to show the runs around each match, "mode" to the
    // next way the query matches.
    Q_INVOKABLE void toggle(const QString& name);
    Q_INVOKABLE void select(int row);
    Q_INVOKABLE void selectPresented(int row, const QString& revision);
    Q_INVOKABLE void search(const QString& query);
    // Applies `word`, a typed filter such as `exit:fail`, as if it were typed and ended.
    Q_INVOKABLE void applyFilter(const QString& word);
    // Removes chip `index`, the last one when it is negative.
    Q_INVOKABLE void removeChip(int index);
    // `text` with its last word completed to the filter name it begins and a colon; empty when
    // Tab has nothing to complete there.
    Q_INVOKABLE [[nodiscard]] QString completeFilter(const QString& text) const;
    // Uses row `row` of the page at once, as Alt and a digit do; nothing while rows load.
    Q_INVOKABLE void quickUse(int row);
    // Uses pin `index` of those the search shows, as Alt, Shift and a digit do.
    Q_INVOKABLE void usePin(int index, bool alternate = false);
    Q_INVOKABLE void setFilters(const QVariantMap& filters);
    Q_INVOKABLE void reportQueryLimit(qulonglong requested_bytes);
    Q_INVOKABLE void registerPanel(QQuickItem* panel);
    Q_INVOKABLE void registerInspector(QQuickItem* inspector);
    Q_INVOKABLE void registerFilters(QQuickItem* filters);
    Q_INVOKABLE void registerFooter(QQuickItem* footer);
    Q_INVOKABLE void registerActions(QQuickItem* actions);

  signals:
    void changed();
    void hoverChanged();
    void inspectionScrolled(int lines);
    // A command from the dialog went to the prompt; closeRequested() follows.
    void submitted();
    // The dialog finished its work, by pasting a command or by visiting its pane. It is emitted
    // inside the interaction, before the store commits it.
    void closeRequested();
    // A failure outside the open dialog, such as a debounced search that could not be sent; the
    // window shows it.
    void failed(const QString& message);

  private:
    friend struct test::HistoryPresentation;

    // The record a row was given, and what it was built from that can change for one command.
    struct CachedRecord {
      HistoryStatus status = HistoryStatus::completed;
      std::int64_t duration_ns = 0;
      ds::Option<std::int32_t> exit_code;
      application::history::HistoryLabels::Text age;
      application::history::HistoryLabels::Text date;
      std::int64_t today = 0;
      // What the query matched, which changes as it is typed.
      application::history::HistoryMarks ranges;
      application::history::HistoryMarks excerpt_ranges;
      std::size_t excerpt = 0;
      bool neighbour = false;
      QVariantMap record;

      [[nodiscard]] bool same(const CachedRecord& other) const noexcept {
        return status == other.status && duration_ns == other.duration_ns && exit_code == other.exit_code && age.view() == other.age.view() && date.view() == other.date.view() && today == other.today && ranges == other.ranges && excerpt_ranges == other.excerpt_ranges && excerpt == other.excerpt && neighbour == other.neighbour;
      }
    };

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

      [[nodiscard]] bool operator==(const Inputs& other) const noexcept {
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
    // Whether the rows shown answer a query older than the one typed: a search waits for its
    // debounce or its first page.
    [[nodiscard]] bool queryPending() const;
    // Whether the rows shown are about to be replaced, by a search or by a page; a refresh keeps
    // them usable.
    [[nodiscard]] bool busy() const;
    [[nodiscard]] const Presented* presented(const QString& revision) const;
    [[nodiscard]] application::history::HistoryActionSurface actionSurface() const;
    [[nodiscard]] application::history::HistoryScrollSurface scrollSurface(HoverFrame& hover) const;
    void submit(std::uint64_t entry_id, bool alternate);
    // Moves the selection `delta` rows, positive to older ones, queueing what a page load stops.
    void step(std::int32_t delta);
    // Runs what was asked for while the rows loaded, once they arrived.
    void settlePending();
    // Sends the delete that waited for its undo.
    void commitRemoval();
    // Sends the query typed while the search before it was in flight, once that one answered.
    void sendQueued();
    // Applies `action` to command `identity`, one of the rows shown.
    void act(Action action, std::uint64_t identity);
    // Replaces the pins' file with the pins; a failure shows in the dialog.
    void savePins();
    // The pins the query matches, newest first, at most as many as Alt and a digit reach.
    [[nodiscard]] QVariantList shownPins() const;
    void notifyHover();
    void query();
    void age();

    // Runs a user's mutation of the session and commits it to the store; a failure shows in the
    // dialog instead.
    template <std::invocable Mutation>
    void interact(Mutation mutate) {
      store_.interact(mutate, [this](const std::exception& error) {
        fail(error);
      });
    }

    Store& store_;
    ListModel rows_;
    QTimer search_timer_;
    // While the dialog is open, ages move on and a running command's row is read again.
    QTimer age_timer_;
    // A delete waits this long for its undo before it goes.
    QTimer undo_timer_;
    // Enter pressed while the rows loaded, with its alternate flag: it runs the row selected once
    // they arrive.
    ds::Option<bool> pending_submit_;
    // The rows moved while they loaded, positive to older ones, bounded by a page.
    std::int32_t pending_moves_ = 0;
    // A query typed while the search before it was in flight, sent once that one answers.
    bool search_queued_ = false;
    QString query_;
    application::history::HistoryFilters filters_;
    std::uint64_t search_version_ = 0;
    CalendarSample calendar_;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rows_version_ = 0;
    // The pins live for the window, in memory of their own.
    SystemAllocator pins_memory_;
    MemoryAdapter<SystemAllocator> pins_adapter_{pins_memory_};
    application::history::HistoryPins pins_{pins_adapter_};
    QByteArray pins_path_;
    // The records of the rows shown, by command, bounded by a page.
    QHash<std::uint64_t, CachedRecord> records_;
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
  };

}
