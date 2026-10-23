#include "layers_probe.hpp"
#import <AppKit/AppKit.h>
#include <QWindow>

namespace layers_probe {
  std::uint32_t windowNumber(QWindow &window) {
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    return static_cast<std::uint32_t>(view.window.windowNumber);
  }

  void setWallpaperLevel(QWindow &window) {
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    view.window.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
  }
} // namespace layers_probe
