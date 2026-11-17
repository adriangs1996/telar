#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QtCore/qnamespace.h>
#include <algorithm>
#include <array>
#include <utility>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  inline constexpr auto mouse_buttons = std::to_array<std::pair<Qt::MouseButton, application::terminal::input::MouseButton>>({
      {Qt::LeftButton, application::terminal::input::MouseButton::left},
      {Qt::MiddleButton, application::terminal::input::MouseButton::middle},
      {Qt::RightButton, application::terminal::input::MouseButton::right},
  });

  inline application::terminal::input::MouseButton mouseButton(Qt::MouseButton button) noexcept {
    const auto* const found = std::ranges::find(mouse_buttons, button, &decltype(mouse_buttons)::value_type::first);

    return found == mouse_buttons.end() ? application::terminal::input::MouseButton::none : found->second;
  }

}
