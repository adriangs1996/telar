#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "terminal/cell_position.hpp"
#include "ui/foundation/store/store.hpp"
#include <QElapsedTimer>
#include <QKeyEvent>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.gui.foundation.terminal;

namespace telar::gui::qt {

  // Copy mode over a pane's scrollback: the keyboard cursor and selection, the pointer's
  // selection, and the search through the scrollback or one command's output.
  //
  // The state lives in the active session; this controller drives it from the keys and the
  // pointer the terminal items deliver, and tells which panes to draw again. The window opens
  // the search line, opens links and shows failures when the controller asks.
  class CopyController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(CopyController)
    QML_UNCREATABLE("Use the window's copy mode")
    Q_PROPERTY(bool active READ active NOTIFY activeChanged)
    // The search as it is typed: its query, whether an answer is awaited, how many matches and
    // which one the cursor is on, and what it reads.
    Q_PROPERTY(QVariantMap searchState READ searchState NOTIFY searchChanged)
    // The command whose output the search reads, empty while it reads the whole scrollback; and
    // whether Tab can switch between the two.
    Q_PROPERTY(QString searchScope READ searchScope NOTIFY searchChanged)
    Q_PROPERTY(bool searchScopes READ searchScopes NOTIFY searchChanged)

  public:
    explicit CopyController(Store& store, QObject* parent = nullptr);
    ~CopyController() override = default;
    CopyController(const CopyController&) = delete;
    CopyController& operator=(const CopyController&) = delete;
    CopyController(CopyController&&) = delete;
    CopyController& operator=(CopyController&&) = delete;

    [[nodiscard]] bool active() const noexcept;
    [[nodiscard]] const std::optional<application::terminal::copy_mode::CopyState>& state() const noexcept;
    [[nodiscard]] QVariantMap searchState() const;
    [[nodiscard]] QString searchScope() const;
    [[nodiscard]] bool searchScopes() const;

    Q_INVOKABLE void toggleSearchScope();
    Q_INVOKABLE void search(const QString& text);
    Q_INVOKABLE void step(bool forward);
    // The search typed so far stays, its matches for n and N; the line goes back to the editor.
    Q_INVOKABLE void finishSearch();

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

  signals:
    void activeChanged();
    void searchChanged();
    void paneChanged(qulonglong pane_id);
    // A key or a pointer press began: a pending key sequence ends.
    void inputStarted();
    void searchRequested();
    void linkRequested(qulonglong pane_id, telar::gui::CellPosition cursor);
    void closeRequested();
    void failed(const QString& message);

  private:
    [[nodiscard]] bool idle() const noexcept;

    Store& store_;
    QElapsedTimer clock_;
    bool published_active_ = false;
  };

}
