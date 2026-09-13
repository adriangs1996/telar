#pragma once
#import <AppKit/AppKit.h>

// Owns native decorations; terminal chrome and navigation remain in Zig.
@interface TelarWindow : NSWindow
@property(nonatomic) BOOL titlebarVisible;
- (void)finishFullscreenTransition;
@end
