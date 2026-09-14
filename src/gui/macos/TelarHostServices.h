#pragma once
#import <AppKit/AppKit.h>
#include "../native/telar_gui.h"

// One clipboard operation is owned until its completion is admitted to Zig.
@interface TelarHostServices : NSObject
- (instancetype)initWithContext:(void *)context callbacks:(const telar_gui_callbacks *)callbacks pasteboard:(NSPasteboard *)pasteboard;
- (void)drain;
- (void)stop;
@end
