#pragma once
#import <AppKit/AppKit.h>

// Native probes locate the input view independently of window chrome.
static NSView *terminal_view(NSView *view) {
    NSString *name = NSStringFromClass(view.class);
    if ([name isEqualToString:@"TelarView"] ||
        ([name containsString:@"SurfaceView"] &&
         [view conformsToProtocol:@protocol(NSTextInputClient)])) return view;
    for (NSView *child in view.subviews) {
        NSView *found = terminal_view(child);
        if (found) return found;
    }
    return nil;
}

