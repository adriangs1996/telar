#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "copy_controller.hpp"
#include "terminal_host.hpp"
#include "ui/app/panes/terminal/prompt/prompt_controller.hpp"
#include "ui/kit/input/mouse_buttons.hpp"
#include "ui/kit/store/store.hpp"
#include <QByteArray>
#include <QHash>
#include <QMouseEvent>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::qt {

  class TerminalItem;

  // The terminals of a window: the item that draws each pane, what they read from the active
  // session, what they write to it, and the pointer each one holds.
  //
  // It reads the store. The window pushes its window and chrome ratio, and tells it when the
  // configuration, the machine, the dialog or a pane moved; the terminals listen to it. What only
  // the window can do, the terminals ask of the TerminalHost it implements.
  class TerminalController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(TerminalController)
    QML_UNCREATABLE("Use the window's terminals")

  public:
    struct Parts {
      Store& store;
      CopyController& copy;
      PromptController& prompt;
      TerminalHost& host;
      ApplicationAllocator& memory;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit TerminalController(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent = nullptr);
    ~TerminalController() override = default;
    TerminalController(const TerminalController&) = delete;
    TerminalController& operator=(const TerminalController&) = delete;
    TerminalController(TerminalController&&) = delete;
    TerminalController& operator=(TerminalController&&) = delete;

    // What a terminal reads: the active session and its panes, the dialog over the workbench, and
    // what it asks of the controllers it holds.
    [[nodiscard]] const GuiSession& session() const noexcept {
      return store_.session();
    }

    [[nodiscard]] GuiSession& sessionMut() noexcept {
      return store_.sessionMut();
    }

    [[nodiscard]] const application::Pane<Memory>* pane(std::uint64_t pane_id) const noexcept {
      return store_.session().findPane(pane_id);
    }

    [[nodiscard]] const Configuration& configuration() const noexcept {
      return store_.session().configuration;
    }

    [[nodiscard]] Store::Dialog dialog() const noexcept {
      return store_.dialog().kind;
    }

    [[nodiscard]] ViewVersion viewVersion() const noexcept;

    [[nodiscard]] Qt::KeyboardModifiers pointerModifiers() const noexcept {
      return pointer_modifiers_;
    }

    [[nodiscard]] qreal chromeRatio() const noexcept {
      return chrome_ratio_;
    }

    [[nodiscard]] CopyController& copy() const noexcept {
      return copy_;
    }

    [[nodiscard]] PromptController& prompt() const noexcept {
      return prompt_;
    }

    [[nodiscard]] TerminalHost& host() const noexcept {
      return host_;
    }

    [[nodiscard]] ApplicationAllocator& memory() const noexcept {
      return memory_;
    }

    // The window the terminals are drawn in, and the ratio its chrome is drawn at.
    void setWindow(QQuickWindow& window);
    void setChromeRatio(qreal ratio) noexcept;

    // The terminal that draws each pane, as the items register themselves.
    void registerTerminal(TerminalItem& terminal);
    void unregisterTerminal(TerminalItem& terminal);
    [[nodiscard]] TerminalItem* terminal(std::uint64_t pane_id) const;
    // The pane's terminal while it draws in the window, or null.
    [[nodiscard]] TerminalItem* visible(std::uint64_t pane_id) const;

    // What the terminals write to the session. A failure goes up as failed().
    bool input(std::uint64_t pane_id, const QByteArray& bytes, application::PaneInputSource source = application::PaneInputSource::keyboard);
    void paste(std::uint64_t pane_id, const QString& text);
    void resize(std::uint64_t pane_id, TerminalSize size);
    void scroll(application::PaneScrollDelta delta);
    // Shows the pane's scrollback from `row`, counted from its top.
    void scrollToRow(std::uint64_t pane_id, std::uint32_t row);
    // Selects a command block of the pane, by index among its blocks, or none to go back to the
    // live end.
    void selectBlock(std::uint64_t pane_id, ds::Option<std::size_t> index, bool typing_leaves = false);
    // Copies the command or the output of a command block of the pane.
    void copyBlock(std::uint64_t pane_id, std::size_t index, application::BlockCopy what);
    // Puts a command block's command in the pane's editor, or runs it again.
    void reuseBlock(std::uint64_t pane_id, std::size_t index, application::BlockReuse how);
    // The same with a command an earlier runtime kept.
    void reuseRestored(std::uint64_t pane_id, std::size_t index, application::BlockReuse how);
    // The filter of a command block's output: opened on it, its query typed, and closed.
    void openFilter(std::uint64_t pane_id, std::size_t index);
    void queryFilter(std::uint64_t pane_id, const application::terminal::filter::Query& query);
    void closeFilter(std::uint64_t pane_id);
    // The window's own step through the pane's blocks, Cmd+Up and Cmd+Down.
    void stepBlock(std::uint64_t pane_id, application::BlockStep direction);
    // The modifiers held over the terminals, from the pointer or the keyboard.
    void observePointerModifiers(Qt::KeyboardModifiers modifiers);
    [[nodiscard]] std::shared_ptr<const application::terminal::links::LinkHit> shareLinkHit(const application::terminal::links::LinkHit& hit);
    // Places the images of the panes the active tab shows in the window.
    void prepareImagePlacements();
    // The pane's keys and pointer are let go before its input goes away.
    void releaseInput(std::uint64_t pane_id);

    // The pointer buttons a terminal holds. Its press acquires the button, and hands a gesture to
    // the program when the program tracks the mouse; its release lets the button go.
    void acquire(TerminalItem& terminal, Qt::MouseButton button);
    void beginChild(const application::terminal::input::ChildMouseView& view, application::terminal::input::ChildMouseSample sample);
    void release(Qt::MouseButton button);
    void abandon(TerminalItem& terminal);
    // The window's pointer while a terminal holds a button: whether one does, a drag delivered to
    // the terminals that hold its buttons, the release of a held button (false when none held
    // it), and every gesture cancelled.
    [[nodiscard]] bool holdsPointer() const noexcept;
    void dragPointer(const QMouseEvent& event);
    [[nodiscard]] bool releasePointer(const QMouseEvent& event);
    void cancelPointer();
    // The terminal a wheel scrolls last; its accumulated scroll ends when another view takes the
    // wheel.
    void observeScroll(TerminalItem& terminal);
    void retireScroll();

  signals:
    void terminalChanged(qulonglong pane_id);
    void inputReleasing(qulonglong pane_id);
    void pointerModifiersChanged();
    // Each refresh of what the window shows from the active session, for the terminals that
    // compare what they read on their own.
    void refreshed();
    void configurationChanged();
    void machineChanged();
    void dialogChanged();
    // The session holds a new notification, such as a reached image limit.
    void notificationPublished();
    void failed(const QString& message);

  private:
    struct Capture {
      QPointer<TerminalItem> terminal;
      application::terminal::input::ChildMouseGesture child{};
      std::uint64_t pane_id = 0;
      bool held = false;
    };

    struct Recipient {
      QPointer<TerminalItem> terminal;
      Qt::MouseButtons view_buttons;
      Qt::MouseButtons child_buttons;
    };

    using Recipients = ds::Array<Recipient, static_cast<std::size_t>(application::terminal::input::MouseButton::none)>;

    [[nodiscard]] Capture* capture(Qt::MouseButton button) noexcept;
    [[nodiscard]] Recipients recipients() const;
    [[nodiscard]] application::terminal::input::ChildMouseView view(const Capture& lease) const;
    [[nodiscard]] static application::terminal::input::ChildMouseSample sample(const QMouseEvent& event, application::terminal::input::MousePhase phase, application::terminal::input::MouseButton button);
    void report(std::uint64_t pane_id, const ds::Option<application::terminal::input::ChildMouseReport>& report);
    void cancelPane(std::uint64_t pane_id);
    static void deliver(TerminalItem& terminal, const QMouseEvent& event, Qt::MouseButtons buttons);

    tbc::mut_a<Store> store_;
    tbc::mut_a<CopyController> copy_;
    tbc::mut_a<PromptController> prompt_;
    tbc::mut_a<TerminalHost> host_;
    tbc::mut_a<ApplicationAllocator> memory_;
    QPointer<QQuickWindow> window_;
    QMetaObject::Connection placements_connection_;
    qreal chrome_ratio_ = 1;
    Qt::KeyboardModifiers pointer_modifiers_;
    QHash<std::uint64_t, QPointer<TerminalItem>> terminals_;
    ds::Array<Capture, static_cast<std::size_t>(application::terminal::input::MouseButton::none)> captures_;
    QPointer<TerminalItem> scroll_owner_;
  };

}
