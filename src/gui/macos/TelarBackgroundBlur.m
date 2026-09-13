#import "TelarBackgroundBlur.h"
#include <dlfcn.h>

typedef void *(*ConnectionForThread)(void);
typedef int32_t (*SetBackgroundRadius)(void *, uintptr_t, int);

@implementation TelarBackgroundBlur {
  uint32_t applied_radius;
}

- (uint32_t)appliedRadius {
  return applied_radius;
}

// Ghostty uses these undocumented CGS functions for numeric blur. Resolve them
// optionally so an OS change can retain public, system-managed blur instead.
// Source: ghostty src/apprt/embedded.zig, ghostty_set_window_background_blur.
// Example: BOOL numeric = [blur applyRadius:40 toWindow:window].
- (BOOL)applyRadius:(uint32_t)radius toWindow:(NSWindow *)window {
  static BOOL resolved, warned;
  static ConnectionForThread connection;
  static SetBackgroundRadius set_radius;
  // All callers belong to the AppKit thread; symbol lookup never repeats on
  // cell frames and needs no cross-thread synchronization.
  if (!resolved) {
    connection = (ConnectionForThread)dlsym(RTLD_DEFAULT, "CGSDefaultConnectionForThread");
    set_radius = (SetBackgroundRadius)dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius");
    resolved = YES;
  }

  if (connection != NULL && set_radius != NULL && window.windowNumber > 0 &&
      set_radius(connection(), (uintptr_t)window.windowNumber, (int)MIN(radius, 255)) == 0) {
    applied_radius = MIN(radius, 255);
    return YES;
  }

  if (radius != 0 && !warned) {
    NSLog(@"telar-gui: numeric background blur unavailable; using system-managed blur");
    warned = YES;
  }

  return radius == 0 && applied_radius == 0;
}
@end
