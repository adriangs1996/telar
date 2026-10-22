#include "../../ui/workbench/keyboard_router.hpp"
#include "session.hpp"
#include <QGuiApplication>
#include <QInputMethod>
#include <stdexcept>

namespace workbench {
  class KeyboardRouter::InputWindow final : public QWindow {};

  KeyboardRouter::KeyboardRouter() = default;
  KeyboardRouter::~KeyboardRouter() = default;

  void KeyboardRouter::adopt(QQuickWindow &window, std::function<void()> requested) {
    window.installEventFilter(this);
    clients_.insert_or_assign(&window, std::move(requested));
    QObject::connect(&window, &QObject::destroyed, this, [this](QObject *destroyed) {
      clients_.erase(destroyed);
    });
  }

  void KeyboardRouter::route(QQuickWindow &window) {
    if (!clients_.contains(&window)) {
      throw std::logic_error("Only adopted windows receive the keyboard");
    }
    if (target_ != &window) {
      QGuiApplication::inputMethod()->commit();
    }
    target_ = &window;
    linux_desktop::focus(window);
  }

  bool KeyboardRouter::holds(const QQuickWindow &window) const {
    return QGuiApplication::focusWindow() == &window;
  }

  bool KeyboardRouter::eventFilter(QObject *watched, QEvent *event) {
    if (event->type() == QEvent::MouseButtonPress || event->type() == QEvent::FocusIn) {
      const auto found = clients_.find(watched);
      if (found != clients_.end() && found->second) {
        const auto callback = found->second;
        callback();
      }
    }
    return false;
  }
} // namespace workbench
