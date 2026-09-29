#pragma once
#include "../native/telar_gui.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

typedef void (^TelarMetalCompletion)(uint64_t token, BOOL success);
// Main-thread report that one accepted image upload stopped reading pixels.
typedef void (^TelarMetalImageReady)(uint32_t handle, BOOL success);

// All public operations run on the main thread. GPU feedback returns there.
@interface TelarMetalRenderer : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
- (instancetype)initWithCompletion:(TelarMetalCompletion)handler
                        imageReady:(TelarMetalImageReady)ready;
// Takes the frame's image releases and uploads; call after every render
// callback, submitted or not, and only while no frame is in flight.
// Example: [renderer acceptImages:&frame].
- (void)acceptImages:(const telar_gui_frame *)frame;
// Copies borrowed frame data before returning. YES schedules one completion
// unless shutdown cancels delivery; NO leaves failure delivery to the caller.
// Example: [renderer renderFrame:&frame drawable:drawable].
- (BOOL)renderFrame:(const telar_gui_frame *)frame
           drawable:(id<CAMetalDrawable>)drawable;
// Stop delivery and wait for submitted GPU work and image uploads before
// releasing its owner.
// Example: [renderer shutdown] when the window closes.
- (void)shutdown;
@end
