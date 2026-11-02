#pragma once

#include "platform/window.hpp"

class QWindow;

namespace telar::gui::platform {

void configureBackgroundEffect(QWindow &window, WindowAppearance appearance);

}
