#pragma once
#import <AppKit/AppKit.h>
#include <stdint.h>

// Isolates the optional WindowServer radius API from the public fallback view.
@interface TelarBackgroundBlur : NSObject
@property(nonatomic, readonly) uint32_t appliedRadius;
- (BOOL)applyRadius:(uint32_t)radius toWindow:(NSWindow *)window;
@end
