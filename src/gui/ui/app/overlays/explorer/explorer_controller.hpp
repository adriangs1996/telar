#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QObject>
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

  // The explorer over the panes: the files of the active machine as a tree a person moves in with
  // Neovim's keys, edits as text and hands to the panes. The controller gives each window the rows
  // it shows and nothing past them, so a directory of any size costs what the window draws.
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
    [[nodiscard]] QVariantList help() const;

    // The rows window `window` shows.
    Q_INVOKABLE QAbstractItemModel* rows(int window);
    // A key the explorer was given; false for one it has no use for.
    Q_INVOKABLE bool key(int key, const QString& text, int modifiers);
    // What was typed in the field of the mode, as it changes and when Enter ends it; and Escape.
    Q_INVOKABLE void typed(const QString& text);
    Q_INVOKABLE void submit(const QString& text);
    Q_INVOKABLE void cancel();
    // The pointer on row `row` of a window, counted from the first row of its listing.
    Q_INVOKABLE void select(int window, int row, bool extend, bool toggle);
    Q_INVOKABLE void activate(int window, int row);
    Q_INVOKABLE void toggleRow(int window, int row);
    // A window shows `rows` rows; the wheel moves what it shows.
    Q_INVOKABLE void setViewport(int window, int rows);
    Q_INVOKABLE void scroll(int window, int rows);
    // Types the keys of a hint, as a click on it asks.
    Q_INVOKABLE void type(const QString& keys);
    // Runs a command as the command line would: `tree`, `w`, `e ~/src`.
    Q_INVOKABLE void run(const QString& command);
    Q_INVOKABLE void close();

    // Opens the explorer at the focused pane, or closes the one that shows.
    void toggle();
    // The session kept an answer about its files, or what the panes show moved.
    void synchronize();
    // The window shows another machine: what the explorer listed was the last one's.
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
    // The explorer opened, and closed: the panes give up the keys, and take them back.
    void opened();
    void closed();
    void failed(const QString& message);

  private:
    // The machine the window shows, as the explorer names it.
    [[nodiscard]] application::explorer::Host host() const;
    // What a use case asks of the window once it returns.
    void finish(application::explorer::Effect effect);
    // What the explorer shows, from what the session holds: each part is told only when it is
    // another than the one shown.
    void publish();
    [[nodiscard]] QVariantList describeWindows() const;
    [[nodiscard]] QVariantList describeLenses() const;
    [[nodiscard]] QVariantMap describeLine() const;
    [[nodiscard]] QVariantList describeHints() const;
    [[nodiscard]] QVariantMap describePreview() const;
    [[nodiscard]] QVariantList describePlan() const;
    [[nodiscard]] QVariantMap record(std::size_t window, std::size_t row) const;

    Store& store_;
    application::explorer::View view_;
    ds::Array<ListModel, 3> rows_;
    QVariantList windows_;
    QVariantList lenses_;
    QVariantMap line_;
    QVariantList hints_;
    QVariantMap preview_;
    QVariantList plan_;
    std::uint64_t revision_ = 0;
    // The home of the account the window runs as, and the active machine's label.
    QByteArray home_;
    mutable QByteArray label_;
  };

}
