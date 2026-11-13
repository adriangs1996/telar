#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <QtCore/qnamespace.h>
#include <array>
#include <utility>

#pragma once


import telar.gui.input.child_mouse;

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
