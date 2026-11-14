module;

#include "platform/window.hpp"

export module telar.gui.platform.background_effect;

export {
  class QWindow;

  namespace telar::gui::platform {

    void configureBackgroundEffect(QWindow& window, WindowAppearance appearance);

  }
}
