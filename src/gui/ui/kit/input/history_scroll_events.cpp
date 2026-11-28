module telar.gui.ui.kit.input;

import telar.gui.qt;

namespace telar::gui::qt {

  NativeScrollFilter::~NativeScrollFilter() {
    if (installed_ && QCoreApplication::instance() != nullptr) {
      QCoreApplication::instance()->removeNativeEventFilter(this);
    }
  }

}
