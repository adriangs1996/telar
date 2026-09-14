#pragma once
#import <AppKit/AppKit.h>
#include "../native/telar_gui.h"

// Retained native elements mirror one delivered, bounded Zig semantic tree.
@interface TelarAccessibility : NSObject
- (instancetype)initWithView:(NSView *)view context:(void *)context callbacks:(const telar_gui_callbacks *)callbacks;
- (void)refresh;
- (NSArray *)children;
- (id)focusedElement;
- (id)hitTest:(NSPoint)screenPoint;
- (void)stop;
@end
