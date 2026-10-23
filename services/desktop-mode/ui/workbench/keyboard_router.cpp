#include "keyboard_router.hpp"
#include "native.hpp"
#include "../../log_categories.hpp"
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
    // Qt's record can be stale: it drops a destroyed focus window without announcing it, and then
    // never reports losing the keyboard to another application. AppKit decides.
    const bool key = input_key_ && native::holdsKeyboard(*input_);
    // A pane's title can come from its terminal, so it stays out of the log.
    qCDebug(telar_log::workbench)
        << "keyboard to a pane" << (key ? "by hand-over" : "by activation");
    if (!key) {
      // Asking Qt alone leaves the keyboard with the application in front, so the process comes
      // to the front first; Qt only learns of activations it asked for itself. focusWindowChanged
      // hands the focus over once Qt sees the input window active.
      native::activate(*input_);
      input_->requestActivate();
    }

    // Qt may already count the input window active and announce nothing.
    if (input_key_) {
      handOver(window);
    }
  }

  bool KeyboardRouter::holds(const QQuickWindow &window) const {
    return input_key_ && QGuiApplication::focusWindow() == &window &&
           native::holdsKeyboard(*input_);
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
    qCDebug(telar_log::workbench) << "focus window"
                                  << (window == input_.get() ? "input"
                                      : pane                 ? "pane"
                                      : window               ? "other"
                                                             : "none");
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
