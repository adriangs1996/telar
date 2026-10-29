#pragma once

#include <cstdint>

class QWindow;

namespace telar::gui::platform {

struct WindowAppearance {
  static constexpr float default_navigation_height = 42;

  bool titlebar = true;
  float navigation_height = default_navigation_height;
  float background_opacity = 1;
  std::uint8_t background_blur = 0;
};

bool defaultTitlebar() noexcept;
bool usesCommandKey() noexcept;
void configureGraphics();
float windowControls(const QWindow &window) noexcept;
void configureWindow(QWindow &window, WindowAppearance appearance);

}
