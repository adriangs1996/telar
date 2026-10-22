#include "keyboard_router.hpp"
#include "native.hpp"
#include "../../trace.hpp"
#include <QGuiApplication>
#include <QScreen>
#include <qpa/qwindowsysteminterface.h>
#include <stdexcept>

namespace workbench {
  // Stays the key window without showing anything: one transparent point on every Space.
  class KeyboardRouter::InputWindow final : public QWindow {
  public:
    explicit InputWindow(KeyboardRouter &router)
        : router_(router) {
      setFlags(Qt::Window | Qt::FramelessWindowHint);
      setTitle(QStringLiteral("Telar Keyboard"));
      setOpacity(0);
      // Only route activates it.
      setProperty("_q_showWithoutActivating", true);

      if (auto *screen = QGuiApplication::primaryScreen()) {
        setGeometry(QRect(screen->availableGeometry().topLeft(), QSize(1, 1)));
      }

      native::prepareInputWindow(*this);
    }

    // Cocoa sends the input method's text and queries to the key window's focus object.
    QObject *focusObject() const override {
      if (auto *target = router_.target_.data()) {
        return target->focusObject();
      }

      return QWindow::focusObject();
    }

  protected:
    // Key events go to the key window, not to Qt's focus window.
    bool event(QEvent *event) override {
      switch (event->type()) {
      case QEvent::KeyPress:
      case QEvent::KeyRelease:
      case QEvent::ShortcutOverride:
        if (auto *target = router_.target_.data()) {
          TELAR_TRACE("workbench.keyboard.forward");
          QCoreApplication::sendEvent(target, event);
          return true;
        }

        break;
      default:
        break;
      }

      return QWindow::event(event);
    }

  private:
    KeyboardRouter &router_;
  };

  KeyboardRouter::KeyboardRouter()
      : input_(std::make_unique<InputWindow>(*this)) {
    input_->show();
    QObject::connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *window) {
      focusWindowChanged(window);
    });
  }

  KeyboardRouter::~KeyboardRouter() {
    // Destroying the input window can change the focus window, which must not reach the router.
    QObject::disconnect(qGuiApp, nullptr, this, nullptr);
    input_.reset();
  }

  void KeyboardRouter::adopt(QQuickWindow &window, std::function<void()> requested) {
    TELAR_TRACE("workbench.keyboard.adopt");
    window.setFlag(Qt::WindowDoesNotAcceptFocus);
    window.installEventFilter(this);
    clients_.insert_or_assign(&window, std::move(requested));
    QObject::connect(&window, &QObject::destroyed, this, [this](QObject *destroyed) {
      clients_.erase(destroyed);
    });
  }

  void KeyboardRouter::route(QQuickWindow &window) {
    TELAR_TRACE("workbench.keyboard.route");
    if (!clients_.contains(&window)) {
      throw std::logic_error("Only adopted windows receive the routed keyboard");
    }

    // A composition in progress belongs to the pane it started in: it is committed there,
    // while the input window still sends the input method to that pane.
    if (target_ != &window && input_key_) {
      native::commitComposition(*input_);
    }

    target_ = &window;
    if (input_key_) {
      handOver(window);
    } else {
      // focusWindowChanged hands the focus over once AppKit has made the input window key.
      input_->requestActivate();
    }
  }

  bool KeyboardRouter::holds(const QQuickWindow &window) const {
    return input_key_ && QGuiApplication::focusWindow() == &window;
  }

  bool KeyboardRouter::eventFilter(QObject *watched, QEvent *event) {
    switch (event->type()) {
    case QEvent::MouseButtonPress: {
      const auto found = clients_.find(watched);
      if (found != clients_.end() && found->second) {
        const auto requested = found->second;
        requested();
      }

      break;
    }
    case QEvent::FocusAboutToChange:
    case QEvent::FocusOut:
      // Qt Quick commits the input method on both, through the pane's own native input context:
      // that activates it with the round trips the router exists to avoid, and route has
      // committed any composition already. The pane keeps its focus item, which has the keyboard
      // again whenever its window is active.
      return handing_over_;
    default:
      break;
    }

    return false;
  }

  void KeyboardRouter::focusWindowChanged(QWindow *window) {
    TELAR_TRACE("workbench.keyboard.focus_window_changed");
    const bool pane = clients_.contains(window);
    if (window == input_.get()) {
      input_key_ = true;
      // Asynchronous: this runs inside Qt's own focus change.
      if (target_) {
        QWindowSystemInterface::handleFocusWindowChanged(target_, Qt::ActiveWindowFocusReason);
      }
    } else if (!pane) {
      input_key_ = false;
    }

    follow(input_key_ && pane ? static_cast<QQuickWindow *>(window) : nullptr);
  }

  // Makes the pane Qt's focus window while the input window stays the key window.
  void KeyboardRouter::handOver(QQuickWindow &window) {
    TELAR_TRACE("workbench.keyboard.hand_over");
    if (QGuiApplication::focusWindow() == &window) {
      return;
    }

    handing_over_ = true;
    QWindowSystemInterface::handleFocusWindowChanged<QWindowSystemInterface::SynchronousDelivery>(
        &window,
        Qt::ActiveWindowFocusReason);
    handing_over_ = false;
  }

  // The input method places its candidate window by mapping the pane's cursor with the input
  // window's position, so Qt must see the input window at the pane's origin. Only Qt's record of
  // the position matters, and updating it costs nothing; moving the native window would cost
  // window server round trips on every focus move.
  void KeyboardRouter::follow(QQuickWindow *window) {
    QObject::disconnect(follow_x_);
    QObject::disconnect(follow_y_);
    if (!window) {
      return;
    }

    const auto place = [this, window] {
      QWindowSystemInterface::handleGeometryChange<QWindowSystemInterface::SynchronousDelivery>(
          input_.get(),
          QRect(window->position(), input_->size()));
    };

    follow_x_ = QObject::connect(window, &QWindow::xChanged, this, place);
    follow_y_ = QObject::connect(window, &QWindow::yChanged, this, place);
    place();
  }
} // namespace workbench
