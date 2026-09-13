#import "TelarView.h"
#import "TelarWindowBackground.h"

int telar_gui_run(const char *title, void *context,
                  const telar_gui_callbacks *callbacks) {
  @autoreleasepool {
    if (@available(macOS 26.0, *)) {
      // Metal 4 is the native renderer's minimum runtime API.
    } else {
      NSLog(@"telar-gui: macOS 26 or later is required for Metal 4");
      return -1;
    }

    // Keep terminal key repeat local to this process, even when macOS enables
    // press-and-hold accents globally. Do not write the user's preferences.
    NSUserDefaults *preferences = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *arguments = [[preferences volatileDomainForName:NSArgumentDomain] mutableCopy];
    arguments[@"ApplePressAndHoldEnabled"] = @NO;
    [preferences setVolatileDomain:arguments forName:NSArgumentDomain];

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
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;

    TelarView *view = [[TelarView alloc] initWithFrame:window.contentView.bounds
                                               context:context
                                             callbacks:callbacks];

    if (view == nil) {
      return -1;
    }

    TelarWindowBackground *background = [[TelarWindowBackground alloc] initWithContentView:view];
    view.backgroundView = background;
    window.contentView = background;
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
