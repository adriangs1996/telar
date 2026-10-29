#pragma once

#include "input/child_mouse.hpp"
#include <QtCore/qnamespace.h>
#include <algorithm>
#include <array>
#include <utility>

namespace telar::gui::qt {

inline constexpr auto mouse_buttons = std::to_array<std::pair<Qt::MouseButton, MouseButton>>({
    {Qt::LeftButton, MouseButton::left},
    {Qt::MiddleButton, MouseButton::middle},
    {Qt::RightButton, MouseButton::right},
});

inline MouseButton mouseButton(Qt::MouseButton button) noexcept {
  const auto *const found = std::ranges::find(mouse_buttons, button, &decltype(mouse_buttons)::value_type::first);

  return found == mouse_buttons.end() ? MouseButton::none : found->second;
}

}
