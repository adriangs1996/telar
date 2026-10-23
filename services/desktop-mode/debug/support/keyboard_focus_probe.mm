#include "keyboard_focus_probe.hpp"
#import <AppKit/AppKit.h>
#include <QWindow>

namespace keyboard_focus_probe {
  void becomeAccessory() {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  }

  bool active() {
    return NSApp.isActive;
  }

  std::string describe(QWindow &input) {
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(input.winId());
    NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.localizedName ?: @"?";
    return std::string("active=") + (NSApp.isActive ? "yes" : "no") +
           " frontmost=" + front.UTF8String +
           " input key=" + (view.window.isKeyWindow ? "yes" : "no") +
           " can become key=" + (view.window.canBecomeKeyWindow ? "yes" : "no");
  }
} // namespace keyboard_focus_probe
