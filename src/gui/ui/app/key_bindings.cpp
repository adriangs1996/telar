#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "key_bindings.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/screen.hpp"
#include "ui/app/chrome/components/components_controller.hpp"
#include "ui/app/panes/attachments/attachments_controller.hpp"
#include "ui/app/panes/terminal/copy_controller.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/foundation/store/store.hpp"
#include "window_commands.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <tuple>
#include <utility>
#include <variant>

#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/input/key_adapter.hpp"
#include "ui/foundation/input/key_encoding.hpp"
#include <QCoreApplication>
#include <QScopedValueRollback>
#include <QtCore/qchar.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <QtGui/qevent.h>
#include <QtQuick/qquickitem.h>
#include <QtQuick/qquickwindow.h>
#include <cstring>

import telar.gui.application.workspace_replica;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;
import telar.gui.input.configuration;
import telar.gui.presentation.history_inspection;

namespace telar::gui::qt {

  namespace {

    bool modifierOnly(int key) noexcept {
      return key == Qt::Key_Shift || key == Qt::Key_Control || key == Qt::Key_Meta || key == Qt::Key_Alt || key == Qt::Key_AltGr || key == Qt::Key_CapsLock || key == Qt::Key_NumLock || key == Qt::Key_ScrollLock;
    }

  }

  KeyBindings::KeyBindings(WindowCommands& commands, Store& store, CopyController& copy, ComponentsController& components, AttachmentsController& attachments, TerminalController& terminals)
      : commands_(commands),
        store_(store),
        copy_(copy),
        components_(components),
        attachments_(attachments),
        terminals_(terminals) {
    clock_.start();
    timeout_.setSingleShot(true);
    connect(&timeout_, &QTimer::timeout, this, &KeyBindings::expire);
    hold_timeout_.setSingleShot(true);
    // A slow binding must not swallow typing: past the limit, held keys go out in order.
    connect(&hold_timeout_, &QTimer::timeout, this, [this] {
      ++hold_epoch_;
      holds_ = 0;
      drain();
    });
  }

  void KeyBindings::setWindow(QQuickWindow& window) {
    if (window_ != nullptr) {
      window_->removeEventFilter(this);
      window_->disconnect(this);
    }

    window_ = &window;
    window.installEventFilter(this);
    connect(&window, &QQuickWindow::activeFocusItemChanged, this, &KeyBindings::cancelSequence);
  }

  std::uint64_t KeyBindings::nowNanoseconds() const noexcept {
    return static_cast<std::uint64_t>(clock_.nsecsElapsed());
  }

  bool KeyBindings::prefixPending() const noexcept {
    return router_.prefixPending();
  }

  tbc::view<ModeHints, tbc::lt::static_storage> KeyBindings::modeHints() const noexcept {
    return ModeHints::resolve(router_);
  }

  void KeyBindings::configure(const InputConfiguration& configuration, const BindingMap<BindingAction>& map) {
    static_cast<void>(apply(router_.interrupt()));
    Router replacement{map, configuration.prefix};

    replacement.inheritLeases(router_);
    replacement.setTimeout(configuration.sequence_timeout_ns);
    router_ = std::move(replacement);
    schedule();
  }

  KeyChord KeyBindings::chord(const QKeyEvent& event) {
    return NativeKeyAdapter::chord(event);
  }

  std::uint64_t KeyBindings::physicalIdentity(const QKeyEvent& event) noexcept {
    constexpr auto scan_tag = std::uint64_t{1} << static_cast<unsigned>(std::numeric_limits<std::uint64_t>::digits - 1);
    constexpr auto native_tag = std::uint64_t{1} << static_cast<unsigned>(std::numeric_limits<std::uint64_t>::digits - 2);

    if (event.nativeScanCode() != 0) {
      return scan_tag | event.nativeScanCode();
    }

    if (event.nativeVirtualKey() != 0) {
      return native_tag | event.nativeVirtualKey();
    }

    return static_cast<std::uint64_t>(event.key() == Qt::Key_Backtab ? Qt::Key_Tab : event.key());
  }

  KeyBindings::RoutedKey KeyBindings::capture(const QKeyEvent& event, QQuickItem& recipient) {
    const auto* terminal = qobject_cast<TerminalItem*>(&recipient);

    auto phase = KeyPhase::press;

    if (event.type() == QEvent::KeyRelease) {
      phase = KeyPhase::release;
    } else if (event.isAutoRepeat()) {
      phase = KeyPhase::repeat;
    }

    return {
        .chord = chord(event),
        .phase = phase,
        .physical = physicalIdentity(event),
        .key = event.key(),
        .modifiers = event.modifiers(),
        .scan = event.nativeScanCode(),
        .native_key = event.nativeVirtualKey(),
        .native_modifiers = event.nativeModifiers(),
        .text = event.text(),
        .recipient = &recipient,
        .owner = terminal == nullptr ? 0 : terminal->paneIdentity(),
    };
  }

  bool KeyBindings::route(QKeyEvent& event, QQuickItem& recipient, bool captures) {
    auto modifiers = event.modifiers();
    const auto pressed = event.type() != QEvent::KeyRelease;

    for (const auto& [key, modifier] : {std::pair{Qt::Key_Shift, Qt::ShiftModifier}, std::pair{Qt::Key_Control, Qt::ControlModifier}, std::pair{Qt::Key_Meta, Qt::MetaModifier}, std::pair{Qt::Key_Alt, Qt::AltModifier}}) {
      if (event.key() == key) {
        modifiers.setFlag(modifier, pressed);
      }
    }

    terminals_.observePointerModifiers(modifiers);
    if (delivering_ || modifierOnly(event.key())) {
      return false;
    }

    if (event.type() == QEvent::KeyRelease && event.isAutoRepeat()) {
      return true;
    }

    if (holds_ > 0) {
      constexpr qsizetype maximum_held_keys = 64;
      if (held_.size() < maximum_held_keys) {
        held_.append(capture(event, recipient));
      }

      return true;
    }

    const auto input = capture(event, recipient);

    try {
      const auto repeating = router_.repeatAction();
      const auto policy = repeating ? repeat(*repeating) : std::nullopt;
      const auto decision = router_.route(input, nowNanoseconds(), {.captures_keys = captures || copy_.active() || store_.dialog().kind != Store::Dialog::none || components_.pickOpen(), .repeat = policy});
      const auto consumed = apply(decision);

      if (input.phase == KeyPhase::release) {
        auto* const lease = std::ranges::find(recipients_, input.physical, &Recipient::physical);
        if (lease != recipients_.end()) {
          *lease = {};
        }
      }

      schedule();

      return consumed;
    } catch (const std::exception& error) {
      router_.eventFailed(input);
      schedule();
      emit failed(QString::fromUtf8(error.what()));

      return true;
    }
  }

  bool KeyBindings::apply(const Decision& decision) {
    switch (decision.outcome) {
    case Outcome::forward:
      return forward(decision.event);
    case Outcome::replay:
      for (const auto& event : std::span{decision.held}.first(decision.held_count)) {
        replay(event);
      }

      if (decision.has_current) {
        replay(decision.event);
      }

      return true;
    case Outcome::action:
      if (commands_.runBinding(decision.action)) {
        router_.actionCompleted(decision, repeat(decision.action));
      } else {
        router_.eventFailed(decision.event);
      }

      return true;
    default:
      return true;
    }
  }

  bool KeyBindings::forward(const RoutedKey& event) {
    auto* lease = std::ranges::find(recipients_, event.physical, &Recipient::physical);

    if (event.phase == KeyPhase::press) {
      if (lease == recipients_.end()) {
        lease = std::ranges::find(recipients_, std::uint64_t{0}, &Recipient::physical);
      }

      if (lease != recipients_.end()) {
        const auto& copy = copy_.state();
        const auto copying = copy && !copy->pointer && store_.dialog().kind == Store::Dialog::none;

        *lease = {.physical = event.physical, .item = event.recipient, .owner = copying ? copy->pane_id : event.owner, .copy_mode = copying, .machine_view = store_.machineView()};
      }

    } else if (lease == recipients_.end()) {
      return true;
    }

    if (lease != recipients_.end() && lease->machine_view != store_.machineView()) {
      *lease = {};

      return true;
    }

    if (lease != recipients_.end() && lease->copy_mode) {
      if (event.phase != KeyPhase::release) {
        const QKeyEvent key{QEvent::KeyPress, event.key, event.modifiers, event.scan, event.native_key, event.native_modifiers, event.text, event.phase == KeyPhase::repeat};

        static_cast<void>(copy_.handleKey(lease->owner, key));
      }

      return true;
    }

    if (event.phase == KeyPhase::press) {
      return false;
    }

    if (event.phase == KeyPhase::repeat && (lease->item != event.recipient || lease->owner != event.owner)) {
      return true;
    }

    if (lease->item != event.recipient) {
      auto redirected = event;

      redirected.recipient = lease->item;
      deliver(redirected);

      return true;
    }

    return false;
  }

  void KeyBindings::replay(const RoutedKey& event) {
    const bool held = router_.hasPhysicalKey(event.physical);

    if (!forward(event)) {
      deliver(event);
    }

    if (!held) {
      auto release = event;

      release.phase = KeyPhase::release;
      if (!forward(release)) {
        deliver(release);
      }

      auto* const lease = std::ranges::find(recipients_, event.physical, &Recipient::physical);
      if (lease != recipients_.end()) {
        *lease = {};
      }
    }
  }

  void KeyBindings::deliver(const RoutedKey& event) {
    if (event.recipient == nullptr) {
      return;
    }

    const QScopedValueRollback guard{delivering_, true};
    QKeyEvent key{event.phase == KeyPhase::release ? QEvent::KeyRelease : QEvent::KeyPress, event.key, event.modifiers, event.scan, event.native_key, event.native_modifiers, event.text, event.phase == KeyPhase::repeat};

    QCoreApplication::sendEvent(event.recipient, &key);
  }

  void KeyBindings::schedule() {
    const auto prefix_pending = router_.prefixPending();
    if (prefix_shown_ != prefix_pending) {
      prefix_shown_ = prefix_pending;
      emit prefixChanged();
    }

    timeout_.stop();
    const auto due = router_.deadline();
    if (due) {
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      const auto now_ns = nowNanoseconds();
      const auto remaining = *due - std::min(*due, now_ns);

      timeout_.start(static_cast<int>((remaining + nanoseconds_per_millisecond - 1) / nanoseconds_per_millisecond));
    }
  }

  void KeyBindings::expire() {
    try {
      static_cast<void>(apply(router_.expire(nowNanoseconds())));
      schedule();
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

  KeyBindings::Hold KeyBindings::hold() {
    constexpr std::chrono::milliseconds hold_limit{250};

    if (holds_++ == 0) {
      hold_timeout_.start(hold_limit);
    }

    return hold_epoch_;
  }

  void KeyBindings::release(Hold hold) {
    if (hold != hold_epoch_ || holds_ == 0 || --holds_ != 0) {
      return;
    }

    hold_timeout_.stop();
    drain();
  }

  void KeyBindings::drain() {
    auto pending = std::exchange(held_, {});

    for (qsizetype index = 0; index < pending.size(); ++index) {
      if (holds_ > 0) {
        // A held key started another Lua binding: the rest wait for that one too.
        held_ = pending.mid(index) + held_;
        return;
      }

      const auto& key = pending[index];
      if (key.recipient == nullptr) {
        continue;
      }

      QKeyEvent event{key.phase == KeyPhase::release ? QEvent::KeyRelease : QEvent::KeyPress, key.key, key.modifiers, key.scan, key.native_key, key.native_modifiers, key.text, key.phase == KeyPhase::repeat};
      if (!route(event, *key.recipient)) {
        deliver(key);
      }
    }
  }

  void KeyBindings::interrupt() {
    static_cast<void>(apply(router_.interrupt()));
    schedule();
  }

  void KeyBindings::cancelSequence() noexcept {
    router_.cancelSequence();
    schedule();
  }

  bool KeyBindings::eventFilter(QObject* watched, QEvent* event) {
    if (watched != window_ || window_ == nullptr) {
      return false;
    }

    if (event->type() == QEvent::WindowDeactivate) {
      router_.clear();
      recipients_.fill({});
      held_.clear();
      schedule();
    }

    const bool key_event = event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease;
    if (!key_event && event->type() != QEvent::ShortcutOverride) {
      return false;
    }

    if (auto* key = dynamic_cast<QKeyEvent*>(event); key != nullptr && attachments_.interceptKey(*key)) {
      event->accept();

      return true;
    }

    auto* recipient = window_->activeFocusItem();
    auto* key = dynamic_cast<QKeyEvent*>(event);
    if (recipient == nullptr || key == nullptr) {
      return false;
    }

    if (event->type() == QEvent::ShortcutOverride && store_.dialog().kind == Store::Dialog::none && router_.wantsBinding(capture(*key, *recipient))) {
      // A dead key (Option+N on macOS) would otherwise start a composition and never arrive as a key press.
      if (auto* terminal = qobject_cast<TerminalItem*>(recipient); terminal != nullptr) {
        terminal->bypassInputMethod();
      }

      event->accept();

      return true;
    }

    if (key_event && qobject_cast<TerminalItem*>(recipient) == nullptr) {
      return route(*key, *recipient);
    }

    return false;
  }

  std::optional<BindingRepeat> KeyBindings::repeat(BindingAction action) const {
    if (store_.dialog().kind != Store::Dialog::none || components_.pickOpen() || (action.kind != BindingActionKind::scroll_pane_up && action.kind != BindingActionKind::scroll_pane_down)) {
      return {};
    }

    const auto* pane = store_.session().focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      return {};
    }

    constexpr std::chrono::milliseconds interval{100};

    return BindingRepeat{.interval_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(interval).count()), .owner = pane->id};
  }

  std::optional<KeyChord> KeyBindings::prefixedKeyForAction(const BindingAction& action) const noexcept {
    return router_.prefixedKeyForAction(action);
  }

  void KeyBindings::synthetic(KeyChord chord, std::uint64_t pane_id, const InputModes& modes) {
    auto key = NativeKeyAdapter::fromChord(chord);

    terminals_.input(pane_id, encodeKey(key, modes));
    key.phase = KeyPhase::release;
    terminals_.input(pane_id, encodeKey(key, modes), PaneInputSource::key_release);
  }

}
