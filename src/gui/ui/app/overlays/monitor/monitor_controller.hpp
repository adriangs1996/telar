#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/input/window_actions.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "ui/foundation/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  // The monitor over the window: the active machine's processors, memory, disks, network and
  // every process, which its runtime answers every 2 s while the monitor shows, and the actions on
  // the process selected in it.
  class MonitorController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(MonitorController)
    QML_UNCREATABLE("Use the window's monitor")
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QVariantMap host READ host NOTIFY changed)
    Q_PROPERTY(QVariantMap view READ view NOTIFY changed)
    Q_PROPERTY(QVariantMap detail READ detail NOTIFY changed)
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
    [[nodiscard]] QVariantMap host() const;
    [[nodiscard]] QVariantMap view() const;
    [[nodiscard]] QVariantMap detail() const;
    [[nodiscard]] QString error() const;
    [[nodiscard]] QAbstractItemModel* rows() noexcept;

    Q_INVOKABLE void setSort(const QString& sort);
    Q_INVOKABLE void toggleReverse();
    Q_INVOKABLE void setScope(const QString& scope);
    Q_INVOKABLE void toggleTree();
    Q_INVOKABLE void setFilter(const QString& filter);
    Q_INVOKABLE void select(int pid, const QString& started);
    Q_INVOKABLE void clearSelection();
    // TERM, KILL, STOP or CONT to the selected process.
    Q_INVOKABLE void signal(const QString& name);
    Q_INVOKABLE void renice(int nice);
    Q_INVOKABLE void copyCommand();
    Q_INVOKABLE void focusPane();
    // Splits the focused pane beside one that runs `telar process review` on the selected process.
    Q_INVOKABLE void review(const QString& tool);
    Q_INVOKABLE void close();

    // The monitor shows: ask now, and every 2 s while it shows.
    void opened();
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

  private:
    void refresh();
    void restart();
    [[nodiscard]] bool showing() const;

    Store& store_;
    ListModel rows_;
    QTimer timer_;
    std::uint64_t revision_ = 0;
  };

}
