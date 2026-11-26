#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/input/window_actions.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QSizeF>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>
#include <string_view>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // The monitor over the window: the active machine's processors, memory, disks, network and
  // every process, which its runtime answers every 2 s while the monitor shows, and the actions on
  // the process selected in it. The process table is laid out in cells of the terminal's font; the
  // controller gives each cell its text, so QML only places it.
  class MonitorController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(MonitorController)
    QML_UNCREATABLE("Use the window's monitor")
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QVariantMap header READ header NOTIFY changed)
    Q_PROPERTY(QVariantList machines READ machines NOTIFY changed)
    Q_PROPERTY(QVariantMap panels READ panels NOTIFY changed)
    Q_PROPERTY(QVariantMap view READ view NOTIFY changed)
    Q_PROPERTY(QVariantList columns READ columns NOTIFY changed)
    Q_PROPERTY(QVariantMap detail READ detail NOTIFY changed)
    Q_PROPERTY(QVariantMap footer READ footer NOTIFY changed)
    Q_PROPERTY(QVariantMap unattributed READ unattributed NOTIFY changed)
    Q_PROPERTY(QVariantMap confirmation READ confirmation NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)

  public:
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
    Q_INVOKABLE void setTable(QSizeF area, QSizeF cell);
    // Moves the rows the table shows by `delta`, keeping the selection.
    Q_INVOKABLE void scroll(int delta);
    // Selects the process `delta` rows from the selected one, and shows it.
    Q_INVOKABLE void move(int delta);
    // Selects the process in the table's row `index`, counted from the first it shows.
    Q_INVOKABLE void selectRow(int index);
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void setSort(const QString& sort);
    Q_INVOKABLE void cycleSort();
    Q_INVOKABLE void toggleReverse();
    Q_INVOKABLE void setScope(const QString& scope);
    Q_INVOKABLE void setLayout(const QString& layout);
    Q_INVOKABLE void toggleTree();
    Q_INVOKABLE void setFilter(const QString& filter);
    // Folds the branch of `pid` in the tree, or unfolds it.
    Q_INVOKABLE void toggleFold(int pid);
    // Folds or unfolds the selected process's branch.
    Q_INVOKABLE void foldSelected(bool folded);
    // STOP or CONT to the selected process; TERM and KILL ask first.
    Q_INVOKABLE void signal(const QString& name);
    // TERM, KILL or attaching the debugger to the process selected now, once confirmed. Another
    // selection or machine cancels it.
    Q_INVOKABLE void ask(const QString& action);
    Q_INVOKABLE void confirm();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void renice(int nice);
    Q_INVOKABLE void copyCommand();
    Q_INVOKABLE void focusPane();
    // Splits the focused pane beside one that runs `telar process review` on the selected process:
    // its stack, files or logs; the debugger asks first.
    Q_INVOKABLE void review(const QString& tool);
    // Shows the machine of the window's list in `slot`, and the monitor with it.
    Q_INVOKABLE void selectMachine(int slot);
    Q_INVOKABLE void close();

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

  signals:
    void changed();
    void closeRequested();
    void failed(const QString& message);
    void filterRequested();
    void machineRequested(application::machines::MachineToken token);

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
  };

}
