#pragma once
#import <AppKit/AppKit.h>

// Owns native decorations; terminal chrome and navigation remain in Zig.
@interface TelarWindow : NSWindow
@property(nonatomic) BOOL titlebarVisible;
// Points of Telar's navigation row; the traffic lights center on it while
// the titlebar is transparent. Example: window.controlsHeight = 42.
@property(nonatomic) CGFloat controlsHeight;
// Points the traffic lights cover from the left edge, zero while they are
// hidden, in the native titlebar or in fullscreen.
- (CGFloat)controlsInset;
- (void)placeControls;
- (void)finishFullscreenTransition;
@end
