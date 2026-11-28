module telar.gui.ui.kit.input;

import telar.gui.qt;
import telar.gui.qt.private_gui;
import telar.tbc;
import telar.gui.foundation.core;

namespace telar::gui::qt {

  struct NativePointerEvents::Native final : QWindowSystemEventHandler {
    Native() {
      if (previous_ != nullptr) {
        QWindowSystemInterfacePrivate::removeWindowSystemEventhandler(previous_);
      }

      QWindowSystemInterfacePrivate::installWindowSystemEventHandler(this);
    }

    ~Native() override;

    Native(const Native&) = delete;
    Native& operator=(const Native&) = delete;
    Native(Native&&) = delete;
    Native& operator=(Native&&) = delete;

    bool sendEvent(QWindowSystemInterfacePrivate::WindowSystemEvent* event) override {
      QEvent::Type kind = QEvent::None;

      if (event->type == QWindowSystemInterfacePrivate::Mouse) {
        // The type tag names the class, as Qt's own dispatch reads it: a dynamic_cast needs the private
        // class's type information, which Linux's Qt keeps inside its library, and throws bad_cast.
        kind = static_cast<const QWindowSystemInterfacePrivate::MouseEvent&>(*event).buttonType; // NOLINT(cppcoreguidelines-pro-type-static-cast-downcast): the event's type tag names its class
      }

      const Dispatch scope{*this, kind};

      return previous_ == nullptr ? QWindowSystemEventHandler::sendEvent(event) : previous_->sendEvent(event);
    }

    [[nodiscard]] bool moving() const noexcept {
      return active_ != nullptr && active_->kind == QEvent::MouseMove;
    }

  private:
    struct Dispatch {
      // The scopes of nested dispatches form a stack of raw links that each scope pops when it ends.
      Dispatch(Native& native, QEvent::Type event_kind)
          : owner(&native),
            previous(native.active_),
            kind(event_kind) {
        native.active_ = tbc::raw(this);
      }

      ~Dispatch() {
        if (owner != nullptr) {
          owner->active_ = previous;
        }
      }

      Dispatch(const Dispatch&) = delete;
      Dispatch& operator=(const Dispatch&) = delete;
      Dispatch(Dispatch&&) = delete;
      Dispatch& operator=(Dispatch&&) = delete;

      Native* owner;
      Dispatch* previous;
      QEvent::Type kind;
    };

    QWindowSystemEventHandler* previous_ = QWindowSystemInterfacePrivate::eventHandler;
    Dispatch* active_ = nullptr;
  };

  NativePointerEvents::Native::~Native() {
    for (auto* scope = active_; scope != nullptr; scope = scope->previous) {
      scope->owner = nullptr;
    }

    auto* const head = QWindowSystemInterfacePrivate::eventHandler;
    if (head == this) {
      QWindowSystemInterfacePrivate::removeWindowSystemEventhandler(this);
      if (previous_ != nullptr) {
        QWindowSystemInterfacePrivate::installWindowSystemEventHandler(previous_);
      }
    } else {
      auto* current = dynamic_cast<Native*>(head);

      while (current != nullptr) {
        if (current->previous_ == this) {
          current->previous_ = previous_;
          break;
        }

        current = dynamic_cast<Native*>(current->previous_);
      }
    }
  }

  NativePointerEvents::NativePointerEvents(ApplicationAllocator& memory)
      : native_(ds::makeBox<Native>(memory)) {}

  NativePointerEvents::~NativePointerEvents() = default;

  bool NativePointerEvents::moving() const noexcept {
    return native_->moving();
  }

}
