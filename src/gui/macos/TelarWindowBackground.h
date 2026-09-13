#pragma once
#import <AppKit/AppKit.h>
#include "../native/telar_gui.h"

// Owns the compositor effect behind the terminal's Metal layer.
@interface TelarWindowBackground : NSView
@property(nonatomic, readonly) uint32_t appliedBlurRadius;
- (instancetype)initWithContentView:(NSView *)content;
- (void)applyFrame:(const telar_gui_frame *)frame;
@end
