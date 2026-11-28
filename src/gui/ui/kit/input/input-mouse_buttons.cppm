export module telar.gui.ui.kit.input:mouse_buttons;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  inline constexpr auto mouse_buttons = ds::Array{
      std::pair{Qt::LeftButton, application::terminal::input::MouseButton::left},
      std::pair{Qt::MiddleButton, application::terminal::input::MouseButton::middle},
      std::pair{Qt::RightButton, application::terminal::input::MouseButton::right},
  };

  [[tbc::hot_path]] inline application::terminal::input::MouseButton mouseButton(Qt::MouseButton button) noexcept {
    const auto* const found = std::ranges::find(mouse_buttons, button, &decltype(mouse_buttons)::value_type::first);

    return found == mouse_buttons.end() ? application::terminal::input::MouseButton::none : found->second;
  }

}
