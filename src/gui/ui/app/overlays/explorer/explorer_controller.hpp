#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
#include <QPointF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  // The explorer over the panes: the files of a machine as a tree a person moves in with Neovim's
  // keys, edits as text and hands to the panes. Each of its windows is on one of the machines the
  // window keeps, and reads the cache the session of that machine holds. The controller gives
  // each window the rows it shows and nothing past them, so a directory of any size costs what
  // the window draws.
  class ExplorerController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(ExplorerController)
    QML_UNCREATABLE("Use the window's explorer")
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(bool showing READ showing NOTIFY changed)
    Q_PROPERTY(bool sideBySide READ sideBySide NOTIFY changed)
    Q_PROPERTY(QVariantList windows READ windows NOTIFY windowsChanged)
    Q_PROPERTY(QVariantList lenses READ lenses NOTIFY lensesChanged)
    Q_PROPERTY(QString scope READ scope NOTIFY changed)
    Q_PROPERTY(QVariantMap line READ line NOTIFY lineChanged)
    Q_PROPERTY(QVariantList hints READ hints NOTIFY hintsChanged)
    Q_PROPERTY(QVariantMap preview READ preview NOTIFY previewChanged)
    Q_PROPERTY(QVariantList plan READ plan NOTIFY planChanged)
    Q_PROPERTY(QVariantMap menu READ menu NOTIFY menuChanged)
    Q_PROPERTY(QVariantList help READ help CONSTANT)

  public:
    explicit ExplorerController(Store& store, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ExplorerController() override = default;
    ExplorerController(const ExplorerController&) = delete;
    ExplorerController& operator=(const ExplorerController&) = delete;
    ExplorerController(ExplorerController&&) = delete;
    ExplorerController& operator=(ExplorerController&&) = delete;

    [[nodiscard]] bool available() const;
    [[nodiscard]] bool showing() const;
    [[nodiscard]] bool sideBySide() const;
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
    [[nodiscard]] static QVariantList help();

    // The rows window `window` shows.
    Q_INVOKABLE QAbstractItemModel* rows(int window);
    // A key the explorer was given; false for one it has no use for.
    Q_INVOKABLE bool key(int key, const QString& text, int modifiers);
    // What was typed in the field of the mode, as it changes and when Enter ends it; and Escape.
    Q_INVOKABLE void typed(const QString& text);
    Q_INVOKABLE void submit(const QString& text);
    Q_INVOKABLE void cancel();
    // `<Tab>` on the command line `text`: what it completes arrives in `line`.
    Q_INVOKABLE void complete(const QString& text);
    // The pointer on row `row` of a window, counted from the first row of its listing.
    Q_INVOKABLE void select(int window, int row, bool extend, bool toggle);
    Q_INVOKABLE void activate(int window, int row);
    Q_INVOKABLE void toggleRow(int window, int row);
    // The pointer asked for the menu of a row, at a place of the explorer; a row below zero is
    // the window itself, and a place below zero the selected row's. And chose a line of it.
    Q_INVOKABLE void openMenu(int window, int row, const QPointF& place);
    Q_INVOKABLE void chooseMenu(int line);
    // Whether a row is part of the selection a drag or a menu would take.
    [[nodiscard]] Q_INVOKABLE bool isChosen(int window, int row) const;
    // The pointer took hold of a row to drag it: how many rows go with it. Then where it is
    // would take `count` of them, in the directory at `row` or in the window's root at -1; and
    // it let them go there, or where nothing takes them.
    Q_INVOKABLE int grab(int window, int row);
    [[nodiscard]] Q_INVOKABLE QVariantMap aim(int window, int row, bool copy) const;
    Q_INVOKABLE void drop(int window, int row, bool copy);
    Q_INVOKABLE void release();
    // A window shows `rows` rows; the wheel moves what it shows.
    Q_INVOKABLE void setViewport(int window, int rows);
    Q_INVOKABLE void scroll(int window, int rows);
    // Types the keys of a hint, as a click on it asks.
    Q_INVOKABLE void type(const QString& keys);
    // Runs a command as the command line would: `tree`, `w`, `e ~/src`.
    Q_INVOKABLE void run(const QString& command);
    // A click on the machine of a window's head: the window goes to the next one, as `gm`.
    Q_INVOKABLE void nextMachine(int window);
    Q_INVOKABLE void close();

    // Opens the explorer at the focused pane, or closes the one that shows.
    void toggle();
    // The session kept an answer about its files, or what the panes show moved.
    void synchronize();
    // The machines changed: the explorer closes when the window shows another one, whose panes
    // are others, and reads their names and reach again otherwise.
    void machineChanged();

  signals:
    void changed();
    // Each part of what the explorer shows says so when it changed, and only then.
    void windowsChanged();
    void lensesChanged();
    void lineChanged();
    void hintsChanged();
    void previewChanged();
    void planChanged();
    void menuChanged();
    // The explorer opened, and closed: the panes give up the keys, and take them back.
    void opened();
    void closed();
    void failed(const QString& message);
    // Files were opened in an editor of a machine the window does not show: it shows it.
    void machineRequested(application::machines::MachineToken token);

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
    // Where the pointer asked for the menu; below zero when the keys did.
    QPointF menu_at_{-1, -1};
    std::uint64_t revision_ = 0;
    // The home of the account the window runs as, which the local machine has before its
    // runtime says it.
    QByteArray home_;
    // What the use cases read around the files, and the cache of a machine that is away: one
    // that holds nothing.
    application::explorer::Scene scene_;
    application::explorer::State away_;
    // The machine the window showed when the explorer last looked.
    application::machines::Machines::Slot shown_ = application::machines::Machines::local_slot;
  };

}
