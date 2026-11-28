export module telar.gui.ui.kit.config:appearance;

import telar.gui.qt;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline Appearance hostAppearance(Qt::ColorScheme scheme) noexcept {
    switch (scheme) {
    case Qt::ColorScheme::Light:
      return Appearance::light;
    case Qt::ColorScheme::Dark:
      return Appearance::dark;
    case Qt::ColorScheme::Unknown:
      return Appearance::unknown;
    }

    return Appearance::unknown;
  }

}
