module telar.gui.ui.design.controls;

import std;
import telar.gui.qt;

namespace telar::gui::qt {

  FormCompositionEvents::FormCompositionEvents(NativeFormField& receiver)
      : receiver_(receiver) {}

  void FormCompositionEvents::setActive(bool active) {
    if (active == installed_) {
      return;
    }

    installed_ = active;
    if (active) {
      QCoreApplication::instance()->installNativeEventFilter(this);
    } else {
      QCoreApplication::instance()->removeNativeEventFilter(this);
    }
  }

  bool FormCompositionEvents::nativeEventFilter(const QByteArray& event_type, void* message, [[maybe_unused]] qintptr* result) {
    return cancelNativeComposition(receiver_, {event_type.constData(), static_cast<std::size_t>(event_type.size())}, message);
  }

}
