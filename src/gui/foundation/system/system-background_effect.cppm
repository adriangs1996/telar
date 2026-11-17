export module telar.gui.foundation.system:background_effect;

import std;

// Qt declares it; the signature below only names it.
extern "C++" class QWindow;

export {
  namespace telar::gui::inline foundation::inline system {

    void configureBackgroundEffect(QWindow& window, float background_opacity, std::uint8_t background_blur);

  }
}
