#include "history_scroll_events.hpp"
#include <QCoreApplication>

namespace telar::gui::qt {

  NativeScrollFilter::~NativeScrollFilter() {
    if (installed_ && QCoreApplication::instance() != nullptr) {
      QCoreApplication::instance()->removeNativeEventFilter(this);
    }
  }

}
