#include "metal_view.hpp"

@implementation TelarMetalView {
  id<MTLCommandQueue> _command_queue;
}

- (instancetype)initWithFrame:(NSRect)frame {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) {
    return nil;
  }

  self = [super initWithFrame:frame device:device];
  if (!self) {
    return nil;
  }

  _command_queue = [device newCommandQueue];
  if (!_command_queue) {
    return nil;
  }

  const MTLClearColor background_color = MTLClearColor(0.08, 0.09, 0.12, 1.0);

  self.clearColor = background_color;
  self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
  self.paused = YES;
  self.enableSetNeedsDisplay = YES;
  self.needsDisplay = YES;

  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  @autoreleasepool {
    MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
    if (!pass) {
      return;
    }

    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (!drawable) {
      return;
    }

    id<MTLCommandBuffer> command_buffer = [_command_queue commandBuffer];
    if (!command_buffer) {
      return;
    }

    id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
      return;
    }

    [encoder endEncoding];
    [command_buffer presentDrawable:drawable];
    [command_buffer commit];
  }
}

@end
