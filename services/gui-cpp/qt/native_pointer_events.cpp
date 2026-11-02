#include "native_pointer_events.hpp"
#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include <QEvent>
#include <QtGui/qpa/qwindowsysteminterface_p.h>

namespace telar::gui::qt {

struct NativePointerEvents::Native final : QWindowSystemEventHandler {
  Native() {
    if (previous_ != nullptr) {
      QWindowSystemInterfacePrivate::removeWindowSystemEventhandler(previous_);
    }

    QWindowSystemInterfacePrivate::installWindowSystemEventHandler(this);
  }

  ~Native() override {
    for (auto *scope = active_; scope != nullptr; scope = scope->previous) {
      scope->owner = nullptr;
    }

    auto *const head = QWindowSystemInterfacePrivate::eventHandler;
    if (head == this) {
      QWindowSystemInterfacePrivate::removeWindowSystemEventhandler(this);
      if (previous_ != nullptr) {
        QWindowSystemInterfacePrivate::installWindowSystemEventHandler(previous_);
      }
    } else {
      auto *current = dynamic_cast<Native *>(head);
      while (current != nullptr) {
        if (current->previous_ == this) {
          current->previous_ = previous_;
          break;
        }

        current = dynamic_cast<Native *>(current->previous_);
      }
    }
  }

  Native(const Native &) = delete;
  Native &operator=(const Native &) = delete;
  Native(Native &&) = delete;
  Native &operator=(Native &&) = delete;

  bool sendEvent(QWindowSystemInterfacePrivate::WindowSystemEvent *event) override {
    QEvent::Type kind = QEvent::None;
    if (event->type == QWindowSystemInterfacePrivate::Mouse) {
      kind = dynamic_cast<const QWindowSystemInterfacePrivate::MouseEvent &>(*event).buttonType;
    }

    const Dispatch scope{*this, kind};

    return previous_ == nullptr ? QWindowSystemEventHandler::sendEvent(event) : previous_->sendEvent(event);
  }

  [[nodiscard]] bool moving() const noexcept {
    return active_ != nullptr && active_->kind == QEvent::MouseMove;
  }

private:
  struct Dispatch {
    Dispatch(Native &native, QEvent::Type event_kind) : owner(&native), previous(native.active_), kind(event_kind) {
      native.active_ = this;
    }

    ~Dispatch() {
      if (owner != nullptr) {
        owner->active_ = previous;
      }
    }

    Dispatch(const Dispatch &) = delete;
    Dispatch &operator=(const Dispatch &) = delete;
    Dispatch(Dispatch &&) = delete;
    Dispatch &operator=(Dispatch &&) = delete;

    Native *owner;
    Dispatch *previous;
    QEvent::Type kind;
  };

  QWindowSystemEventHandler *previous_ = QWindowSystemInterfacePrivate::eventHandler;
  Dispatch *active_ = nullptr;
};

NativePointerEvents::NativePointerEvents(ApplicationAllocator &memory)
    : native_(makeOwned<Native>(memory)) {}

NativePointerEvents::~NativePointerEvents() = default;

bool NativePointerEvents::moving() const noexcept {
  return native_->moving();
}

}
