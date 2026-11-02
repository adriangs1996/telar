#pragma once

#include "input/action.hpp"
#include "input/configuration.hpp"
#include "input/key_event.hpp"
#include "input/key_router.hpp"
#include "presentation/mode_hints.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <QElapsedTimer>
#include <QKeyEvent>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTimer>
#include <array>
#include <cstdint>

namespace telar::gui::qt {

class Application;

class KeyBindings final : public QObject {
public:
  explicit KeyBindings(Application &application);
  void setWindow(QQuickWindow &window);
  void configure(const InputConfiguration &configuration, const BindingMap<BindingAction> &map);
  bool route(QKeyEvent &event, QQuickItem &recipient, bool captures = false);
  void interrupt();
  void cancelSequence() noexcept;
  void synthetic(KeyChord chord, std::uint64_t pane_id, const InputModes &modes);
  [[nodiscard]] std::optional<KeyChord> prefixedKeyForAction(const BindingAction &action) const noexcept;
  [[nodiscard]] std::uint64_t nowNanoseconds() const noexcept;
  [[nodiscard]] bool prefixPending() const noexcept;
  [[nodiscard]] ModeHints modeHints() const noexcept;

  bool eventFilter(QObject *watched, QEvent *event) override;

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

  using Router = KeyRouter<BindingAction, RoutedKey>;
  using Decision = Router::Decision;
  using Outcome = Router::Outcome;

  static KeyChord chord(const QKeyEvent &event);
  static std::uint64_t physicalIdentity(const QKeyEvent &event) noexcept;
  static RoutedKey capture(const QKeyEvent &event, QQuickItem &recipient);
  bool apply(const Decision &decision);
  bool forward(const RoutedKey &event);
  void replay(const RoutedKey &event);
  void deliver(const RoutedKey &event);
  void schedule();
  void expire();

  Application &application_;
  Router router_;
  QPointer<QQuickWindow> window_;
  QElapsedTimer clock_;
  QTimer timeout_;
  std::array<Recipient, BindingLimits::physical_keys> recipients_{};
  bool delivering_ = false;
  bool prefix_shown_ = false;
};

}
