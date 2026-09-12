#pragma once
#include "../native/telar_gui.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

typedef void (^TelarMetalCompletion)(uint64_t token, BOOL success);

// All public operations run on the main thread. GPU feedback returns there.
@interface TelarMetalRenderer : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
- (instancetype)initWithCompletion:(TelarMetalCompletion)handler;
// Copies borrowed frame data before returning. YES schedules one completion
// unless shutdown cancels delivery; NO leaves failure delivery to the caller.
// Example: [renderer renderFrame:&frame drawable:drawable].
- (BOOL)renderFrame:(const telar_gui_frame *)frame
           drawable:(id<CAMetalDrawable>)drawable;
// Stop delivery and wait for submitted GPU work before releasing its owner.
// Example: [renderer shutdown] when the window closes.
- (void)shutdown;
@end
