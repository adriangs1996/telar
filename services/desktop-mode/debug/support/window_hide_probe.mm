#include "window_hide_probe.hpp"
#import <AppKit/AppKit.h>
#include <QWindow>
#include <mach/mach.h>

namespace {
  NSWindow *nativeWindow(QWindow &window) {
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    return view.window;
  }
} // namespace

void window_hide_probe::setIgnoresMouse(QWindow &window, bool ignores) {
  nativeWindow(window).ignoresMouseEvents = ignores;
}

std::uint32_t window_hide_probe::windowNumber(QWindow &window) {
  return static_cast<std::uint32_t>(nativeWindow(window).windowNumber);
}

std::uint32_t window_hide_probe::windowAt(QPointF point) {
  // Qt's global coordinates start at the top of the main screen; AppKit's at its bottom.
  const auto top = NSMaxY(NSScreen.screens.firstObject.frame);
  return static_cast<std::uint32_t>(
      [NSWindow windowNumberAtPoint:NSMakePoint(point.x(), top - point.y())
          belowWindowWithWindowNumber:0]);
}

std::uint64_t window_hide_probe::footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) !=
      KERN_SUCCESS) {
    return 0;
  }

  return info.phys_footprint;
}
