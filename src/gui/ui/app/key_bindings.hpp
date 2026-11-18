#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

#include "telar_wire/serializers/telar_frame.hpp"
#include <QElapsedTimer>
#include <QKeyEvent>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>

#pragma once

import telar.gui.application;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.base.ds;

namespace telar::gui::qt {

  class AttachmentsController;
  class ComponentsController;
  class CopyController;
  class Store;
  class TerminalController;
  class WindowCommands;

  // Routes the window's keys: a binding runs the window's action, the rest reach the item that has
  // the focus, or the pane copy mode reads. It holds every recipient a key can have.
  class KeyBindings final : public QObject {
    Q_OBJECT

  public:
    KeyBindings(WindowCommands& commands, Store& store, CopyController& copy, ComponentsController& components, AttachmentsController& attachments, TerminalController& terminals);
    void setWindow(QQuickWindow& window);
    void configure(const InputConfiguration& configuration, const BindingMap<BindingAction>& map);
    bool route(QKeyEvent& event, QQuickItem& recipient, bool captures = false);
    void interrupt();
    void cancelSequence() noexcept;
    void synthetic(KeyChord chord, std::uint64_t pane_id, const InputModes& modes);
    [[nodiscard]] ds::Option<KeyChord> prefixedKeyForAction(const BindingAction& action) const noexcept;
    [[nodiscard]] std::uint64_t nowNanoseconds() const noexcept;
    [[nodiscard]] bool prefixPending() const noexcept;
    [[nodiscard]] tbc::view<application::status_bar::ModeHints, tbc::lt::static_storage> modeHints() const noexcept;
    // Keys typed while a Lua binding runs on the Lua thread wait for its result, so a key
    // never reaches a pane the binding was about to leave.
    using Hold = std::uint64_t;
    [[nodiscard]] Hold hold();
    void release(Hold hold);

    bool eventFilter(QObject* watched, QEvent* event) override;

  signals:
    void failed(const QString& message);
    // A prefix started waiting for its key, or stopped.
    void prefixChanged();

  private:
    struct RoutedKey {
      KeyChord chord;
      KeyPhase phase = KeyPhase::press;
      std::uint64_t physical = 0;
      int key = 0;
      Qt::KeyboardModifiers modifiers;
      quint32 scan = 0;
      quint32 native_key = 0;
      quint32 native_modifiers = 0;
      QString text;
      QPointer<QQuickItem> recipient;
      std::uint64_t owner = 0;
    };

    struct Recipient {
      std::uint64_t physical = 0;
      QPointer<QQuickItem> item;
      std::uint64_t owner = 0;
      bool copy_mode = false;
      std::uint64_t machine_view = 0;
    };

    using Router = application::bindings::KeyRouter<BindingAction, RoutedKey>;
    using Decision = Router::Decision;
    using Outcome = Router::Outcome;

    static KeyChord chord(const QKeyEvent& event);
    static std::uint64_t physicalIdentity(const QKeyEvent& event) noexcept;
    static RoutedKey capture(const QKeyEvent& event, QQuickItem& recipient);
    // Scrolling a pane repeats while its key is held, when no dialog takes the keys.
    [[nodiscard]] ds::Option<BindingRepeat> repeat(BindingAction action) const;
    bool apply(const Decision& decision);
    bool forward(const RoutedKey& event);
    // The recipient a physical key is leased to, or a free one for key 0; null when there is none.
    Recipient* leaseOf(std::uint64_t physical) noexcept;
    void replay(const RoutedKey& event);
    void deliver(const RoutedKey& event);
    void schedule();
    void expire();
    void drain();

    WindowCommands& commands_;
    Store& store_;
    CopyController& copy_;
    ComponentsController& components_;
    AttachmentsController& attachments_;
    TerminalController& terminals_;
    Router router_;
    QPointer<QQuickWindow> window_;
    QElapsedTimer clock_;
    QTimer timeout_;
    ds::Array<Recipient, BindingLimits::physical_keys> recipients_{};
    bool delivering_ = false;
    bool prefix_shown_ = false;
    QList<RoutedKey> held_;
    QTimer hold_timeout_;
    std::size_t holds_ = 0;
    Hold hold_epoch_ = 0;
  };

}
