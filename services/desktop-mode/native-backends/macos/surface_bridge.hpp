#pragma once

#import <AppKit/AppKit.h>

struct QuickSurface;

@interface TelarSurfaceBridge : NSObject
- (instancetype)initWithView:(NSView *)view surface:(QuickSurface &)surface;
@end
