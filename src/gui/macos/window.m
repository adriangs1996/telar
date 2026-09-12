#import "TelarView.h"

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks) {
  @autoreleasepool {
    if (@available(macOS 26.0, *)) {
      // Metal 4 is the native renderer's minimum runtime API.
    } else {
      NSLog(@"telar-gui: macOS 26 or later is required for Metal 4");
      return -1;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
                                    styleMask:NSWindowStyleMaskTitled |
                                              NSWindowStyleMaskClosable |
                                              NSWindowStyleMaskResizable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];

    window.title = [NSString stringWithUTF8String:title];
    window.minSize = NSMakeSize(320, 200);
    window.releasedWhenClosed = NO;

    TelarView *view = [[TelarView alloc] initWithFrame:window.contentView.bounds
                                               context:context
                                             callbacks:callbacks];

    if (view == nil) {
      return -1;
    }

    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = view;
    window.delegate = view;
    [view startWakeSource];
    [window makeFirstResponder:view];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    window.delegate = nil;
    [window close];

    return 0;
  }
}
