export module telar.gui.platform.background_effect;

import std;

export {
  class QWindow;

  namespace telar::gui::platform {

    void configureBackgroundEffect(QWindow& window, float background_opacity, std::uint8_t background_blur);

  }
}
