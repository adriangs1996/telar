#import "TelarMetalRenderer.h"
#include <string.h>
#include "../native/diagram_textures.h"

static const unsigned char shader_source[] = {
#embed "../shaders/quad.metal"
};

@implementation TelarMetalRenderer {
  id<MTLDevice> device;
  id<MTL4CommandQueue> queue;
  id<MTL4CommandBuffer> commands;
  id<MTL4CommandAllocator> command_allocator;
  id<MTL4ArgumentTable> arguments;
  id<MTLResidencySet> residency;
  id<MTLBuffer> viewport_buffer;
  MTL4CommitOptions *commit_options;
  MTL4RenderPassDescriptor *render_pass;
  id<CAMetalDrawable> active_drawable;
  MTL4CommitFeedbackHandler feedback_handler;
  dispatch_group_t gpu_work;
  uint64_t active_token;
  id<MTLRenderPipelineState> pipeline;
  id<MTLTexture> atlas;
  id<MTLTexture> sprites;
  id<MTLTexture> diagrams[TELAR_GUI_DIAGRAM_SLOTS];
  uint64_t diagram_versions[TELAR_GUI_DIAGRAM_SLOTS];
  id<MTLBuffer> quads;
  uint32_t atlas_version;
  uint32_t sprites_version;
  BOOL in_flight, stopped;
  TelarMetalCompletion completion;
}

- (instancetype)initWithCompletion:(TelarMetalCompletion)handler {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  completion = [handler copy];
  device = MTLCreateSystemDefaultDevice();
  if (device == nil || ![device supportsFamily:MTLGPUFamilyMetal4]) {
    NSLog(@"telar-gui: Metal 4 requires a supported Apple GPU");
    return nil;
  }

  if (![self buildSubmission] || ![self buildPipeline]) {
    return nil;
  }

  return self;
}

- (id<MTLDevice>)device {
  return device;
}

- (BOOL)isBusy {
  return in_flight;
}

// Initialize the single reusable submission slot, e.g. [self buildSubmission].
- (BOOL)buildSubmission {
  queue = [device newMTL4CommandQueue];
  commands = [device newCommandBuffer];
  command_allocator = [device newCommandAllocator];
  MTL4ArgumentTableDescriptor *bindings = [MTL4ArgumentTableDescriptor new];
  bindings.maxBufferBindCount = 2;
  bindings.maxTextureBindCount = 2 + TELAR_GUI_DIAGRAM_SLOTS;
  NSError *error = nil;
  arguments = [device newArgumentTableWithDescriptor:bindings error:&error];
  MTLResidencySetDescriptor *resident = [MTLResidencySetDescriptor new];
  resident.initialCapacity = 5 + TELAR_GUI_DIAGRAM_SLOTS;
  residency = [device newResidencySetWithDescriptor:resident error:&error];
  viewport_buffer = [device newBufferWithLength:sizeof(float) * 2
                                        options:MTLResourceStorageModeShared];

  if (queue == nil || commands == nil || command_allocator == nil ||
      arguments == nil || residency == nil || viewport_buffer == nil) {
    NSLog(@"telar-gui: Metal 4 resource initialization failed: %@", error);
    return NO;
  }

  [queue addResidencySet:residency];
  gpu_work = dispatch_group_create();
  commit_options = [MTL4CommitOptions new];
  render_pass = [MTL4RenderPassDescriptor new];
  __weak TelarMetalRenderer *weak = self;
  dispatch_group_t completion_group = gpu_work;
  feedback_handler = ^(id<MTL4CommitFeedback> feedback) {
    BOOL success = feedback.error == nil;
    if (!success) {
      NSLog(@"telar-gui: Metal 4 submission failed: %@", feedback.error);
    }

    dispatch_group_leave(completion_group);
    dispatch_async(dispatch_get_main_queue(), ^{
      TelarMetalRenderer *renderer = weak;
      if (renderer == nil || renderer->stopped) {
        return;
      }

      renderer->in_flight = NO;
      renderer->active_drawable = nil;
      renderer->completion(renderer->active_token, success);
    });
  };
  return YES;
}

- (BOOL)buildPipeline {
  NSError *error = nil;
  NSString *source = [[NSString alloc] initWithBytes:shader_source
                                              length:sizeof(shader_source)
                                            encoding:NSUTF8StringEncoding];
  MTL4CompilerDescriptor *compiler_descriptor = [MTL4CompilerDescriptor new];
  id<MTL4Compiler> compiler =
      [device newCompilerWithDescriptor:compiler_descriptor error:&error];
  if (compiler == nil) {
    NSLog(@"telar-gui: Metal 4 compiler creation failed: %@", error);
    return NO;
  }

  MTL4LibraryDescriptor *library_descriptor = [MTL4LibraryDescriptor new];
  MTLCompileOptions *compile_options = [MTLCompileOptions new];
  compile_options.languageVersion = MTLLanguageVersion4_0;
  library_descriptor.options = compile_options;
  library_descriptor.source = source;
  library_descriptor.name = @"Telar quad shaders";
  id<MTLLibrary> library = [compiler newLibraryWithDescriptor:library_descriptor
                                                        error:&error];
  if (library == nil) {
    NSLog(@"telar-gui: shader compilation failed: %@", error);
    return NO;
  }

  MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
  vertex.library = library;
  vertex.name = @"quad_vertex";
  MTL4LibraryFunctionDescriptor *fragment = [MTL4LibraryFunctionDescriptor new];
  fragment.library = library;
  fragment.name = @"quad_fragment";

  MTL4RenderPipelineDescriptor *descriptor = [MTL4RenderPipelineDescriptor new];
  descriptor.vertexFunctionDescriptor = vertex;
  descriptor.fragmentFunctionDescriptor = fragment;

  MTL4RenderPipelineColorAttachmentDescriptor *color =
      descriptor.colorAttachments[0];

  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingState = MTL4BlendStateEnabled;
  color.rgbBlendOperation = MTLBlendOperationAdd;
  color.alphaBlendOperation = MTLBlendOperationAdd;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

  pipeline = [compiler newRenderPipelineStateWithDescriptor:descriptor
                                        compilerTaskOptions:nil
                                                      error:&error];
  if (pipeline == nil) {
    NSLog(@"telar-gui: pipeline creation failed: %@", error);
    return NO;
  }
  return YES;
}

- (BOOL)uploadAtlas:(const telar_gui_frame *)frame {
  if (frame->atlas == NULL || frame->atlas_side == 0) {
    return YES;
  }

  if (atlas == nil || atlas.width != frame->atlas_side) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                     width:frame->atlas_side
                                    height:frame->atlas_side
                                 mipmapped:NO];

    descriptor.usage = MTLTextureUsageShaderRead;
    atlas = [device newTextureWithDescriptor:descriptor];
    if (atlas == nil) {
      return NO;
    }

    atlas_version = 0;
  }

  if (atlas_version == frame->atlas_version) {
    return YES;
  }

  [atlas
      replaceRegion:MTLRegionMake2D(0, 0, frame->atlas_side, frame->atlas_side)
        mipmapLevel:0
          withBytes:frame->atlas
        bytesPerRow:frame->atlas_side];

  atlas_version = frame->atlas_version;
  return YES;
}

// The premultiplied RGBA sprite page beside the atlas; uploaded once per
// version like the atlas, e.g. after a favicon lands. A frame without sprites
// leaves the previous texture in place.
- (BOOL)uploadSprites:(const telar_gui_frame *)frame {
  if (frame->sprites == NULL || frame->sprites_side == 0) {
    return YES;
  }

  if (sprites == nil || sprites.width != frame->sprites_side) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:frame->sprites_side
                                    height:frame->sprites_side
                                 mipmapped:NO];

    descriptor.usage = MTLTextureUsageShaderRead;
    sprites = [device newTextureWithDescriptor:descriptor];
    if (sprites == nil) {
      return NO;
    }

    sprites_version = 0;
  }

  if (sprites_version == frame->sprites_version) {
    return YES;
  }

  [sprites replaceRegion:MTLRegionMake2D(0, 0, frame->sprites_side,
                                         frame->sprites_side)
             mipmapLevel:0
               withBytes:frame->sprites
             bytesPerRow:frame->sprites_side * 4];

  sprites_version = frame->sprites_version;
  return YES;
}

// Only called with no submission in flight. Release replaced slots before
// allocating new ones so the retained image quota does not double on resize.
- (BOOL)uploadDiagrams:(const telar_gui_frame *)frame {
  for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
    const telar_gui_diagram_texture *source = &frame->diagrams[i];
    if (!source->pixels || diagrams[i].width != source->width ||
        diagrams[i].height != source->height) {
      diagrams[i] = nil;
      diagram_versions[i] = 0;
    }
  }
  for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
    const telar_gui_diagram_texture *source = &frame->diagrams[i];
    if (!source->pixels) {
      continue;
    }
    if (diagrams[i] == nil) {
      MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                       width:source->width
                                      height:source->height
                                   mipmapped:NO];
      descriptor.usage = MTLTextureUsageShaderRead;
      diagrams[i] = [device newTextureWithDescriptor:descriptor];
      if (diagrams[i] == nil) {
        return NO;
      }
    }
    if (diagram_versions[i] != source->version) {
      [diagrams[i] replaceRegion:MTLRegionMake2D(0, 0, source->width, source->height)
                    mipmapLevel:0
                      withBytes:source->pixels
                    bytesPerRow:(NSUInteger)source->width * 4];
      diagram_versions[i] = source->version;
    }
  }
  return YES;
}

- (BOOL)renderFrame:(const telar_gui_frame *)frame
           drawable:(id<CAMetalDrawable>)drawable {
  if (stopped || in_flight || drawable == nil ||
      !telar_gui_diagrams_valid(frame, TELAR_GUI_DIAGRAM_MAX_SIDE)) {
    return NO;
  }

  // A residency set keeps committed allocations alive. Retire the completed
  // set before replacing image slots, not after allocating their replacements.
  [residency removeAllAllocations];
  [residency commit];
  CGSize size = CGSizeMake(drawable.texture.width, drawable.texture.height);
  if (![self uploadAtlas:frame] || ![self uploadSprites:frame] || ![self uploadDiagrams:frame]) {
    return NO;
  }

  MTL4RenderPassDescriptor *pass = render_pass;

  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  pass.colorAttachments[0].clearColor =
      MTLClearColorMake(frame->background[0] * frame->background[3],
                        frame->background[1] * frame->background[3],
                        frame->background[2] * frame->background[3], frame->background[3]);

  // Only the completion callback releases in_flight, so resetting cannot
  // invalidate command memory or resources still read by the GPU.
  [command_allocator reset];
  [commands beginCommandBufferWithAllocator:command_allocator];

  id<MTL4RenderCommandEncoder> encoder =
      [commands renderCommandEncoderWithDescriptor:pass];

  if (encoder == nil) {
    [commands endCommandBuffer];
    return NO;
  }

  if (frame->quad_count > 0 && frame->quads != NULL && atlas != nil) {
    NSUInteger bytes = frame->quad_count * sizeof(telar_gui_quad);

    if (quads == nil || quads.length < bytes) {
      quads = [device newBufferWithLength:MAX(bytes, (NSUInteger)4096)
                                  options:MTLResourceStorageModeShared];
    }

    if (quads == nil) {
      [encoder endEncoding];
      [commands endCommandBuffer];
      return NO;
    }

    memcpy(quads.contents, frame->quads, bytes);
    float viewport_size[2] = {(float)size.width, (float)size.height};

    [encoder setRenderPipelineState:pipeline];
    memcpy(viewport_buffer.contents, viewport_size, sizeof viewport_size);
    [arguments setAddress:quads.gpuAddress atIndex:0];
    [arguments setAddress:viewport_buffer.gpuAddress atIndex:1];
    [arguments setTexture:atlas.gpuResourceID atIndex:0];
    // Every argument slot the shader declares is bound; without a sprite
    // page the atlas stands in and no quad selects it.
    id<MTLTexture> sprite_page = sprites != nil ? sprites : atlas;
    [arguments setTexture:sprite_page.gpuResourceID atIndex:1];
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
      id<MTLTexture> image = diagrams[i] != nil ? diagrams[i] : atlas;
      [arguments setTexture:image.gpuResourceID atIndex:2 + i];
    }
    [encoder setArgumentTable:arguments
                     atStages:MTLRenderStageVertex | MTLRenderStageFragment];

    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6
              instanceCount:frame->quad_count];
  }

  [encoder endEncoding];
  [commands endCommandBuffer];

  // Residency makes addresses accessible; strong ivars keep resources alive.
  // The previous submission is complete before this set can change.
  [residency removeAllAllocations];
  [residency addAllocation:viewport_buffer];
  [residency addAllocation:drawable.texture];
  if (quads != nil) {
    [residency addAllocation:quads];
  }

  if (atlas != nil) {
    [residency addAllocation:atlas];
  }

  if (sprites != nil) {
    [residency addAllocation:sprites];
  }

  for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
    if (diagrams[i] != nil) {
      [residency addAllocation:diagrams[i]];
    }
  }

  [residency commit];
  in_flight = YES;
  active_token = frame->token;
  active_drawable = drawable;
  dispatch_group_enter(gpu_work);
  [queue waitForDrawable:drawable];
  id<MTL4CommandBuffer> batch[] = {commands};
  // Commit consumes registered handlers; re-arm the same block for each frame.
  [commit_options addFeedbackHandler:feedback_handler];
  [queue commit:batch count:1 options:commit_options];
  [queue signalDrawable:drawable];
  [drawable present];
  return YES;
}

- (void)shutdown {
  stopped = YES;
  completion = nil;
  if (in_flight) {
    dispatch_group_wait(gpu_work, DISPATCH_TIME_FOREVER);
  }

  in_flight = NO;
  active_drawable = nil;
}

@end
