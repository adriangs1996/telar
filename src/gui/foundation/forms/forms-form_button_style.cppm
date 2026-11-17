export module telar.gui.foundation.forms:form_button_style;

import std;

import telar.gui.foundation.drawing;

// Interface: presentation/form_button_style.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    struct FormButtonStyle {
      static constexpr float radius = ChromeStyle::control_radius;
      static constexpr float disabled_alpha = 0.4F;
      static constexpr float pressed_alpha = 0.8F;
    };

  }
}
