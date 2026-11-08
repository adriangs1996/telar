#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <cstdlib>
#include <exception>
#include <iostream>
#import <simd/simd.h>
#include <stdexcept>
#include <vector>

namespace {

struct Quad {
  simd_float4 rect;
  simd_float4 uv;
  simd_float4 color;
  simd_float4 shape;
  simd_float4 border_color;
};

void require(bool condition, NSString *message) {
  if (!condition) {
    throw std::runtime_error{message == nil ? "Metal reference failed" : message.UTF8String};
  }
}

NSString *_Nonnull argument(const char *value) {
  NSString *const result = [NSString stringWithUTF8String:value];
  if (result == nil) {
    throw std::invalid_argument{"Arguments must be UTF-8"};
  }

  return result;
}

simd_float4 vector(NSArray<NSNumber *> *values, float opacity = 1) {
  return {values[0].floatValue, values[1].floatValue, values[2].floatValue, values[3].floatValue * opacity};
}

id<MTLRenderPipelineState> pipeline(id<MTLDevice> device, NSString *source) {
  NSError *error = nil;
  auto *const options = [MTLCompileOptions new];
  options.languageVersion = MTLLanguageVersion4_0;
  const id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
  require(library != nil, error.description);

  auto *const descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"quad_fragment"];
  auto *const color = descriptor.colorAttachments[0];
  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingEnabled = YES;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  const id<MTLRenderPipelineState> result = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  require(result != nil, error.description);

  return result;
}

void save(id<MTLTexture> texture, NSString *path) {
  constexpr std::size_t bytes_per_pixel = 4;
  constexpr std::size_t bits_per_channel = 8;
  const auto stride = texture.width * bytes_per_pixel;
  NSMutableData *const pixels = [NSMutableData dataWithLength:stride * texture.height];
  [texture getBytes:pixels.mutableBytes bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(texture.width, texture.height, bits_per_channel, bytes_per_pixel * bits_per_channel, stride, color_space, static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little) | static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst), provider, nullptr, false, kCGRenderingIntentDefault);
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
  require(image != nullptr && destination != nullptr, @"Could not create the reference image");
  CGImageDestinationAddImage(destination, image, nullptr);
  require(CGImageDestinationFinalize(destination), @"Could not save the reference image");
  CFRelease(destination);
  CGImageRelease(image);
  CGColorSpaceRelease(color_space);
  CGDataProviderRelease(provider);
}

void render(id<MTLDevice> device, NSString *source, NSDictionary *request, NSString *output) {
  const auto width = [request[@"width"] unsignedIntegerValue];
  const auto height = [request[@"height"] unsignedIntegerValue];
  std::vector<Quad> quads;
  for (NSDictionary *record in request[@"shapes"]) {
    const auto rect = vector(record[@"rect"]);
    const auto radius = std::min([record[@"radius"] floatValue], std::min(rect.z, rect.w) / 2);
    const auto opacity = [record[@"opacity"] floatValue];
    const auto fill = vector(record[@"fill"], opacity);
    const auto border = vector(record[@"border"], opacity);
    quads.push_back({.rect = rect, .uv = {}, .color = fill, .shape = {radius, [record[@"borderWidth"] floatValue], 0, 0}, .border_color = border});
  }

  auto *const target_descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
  target_descriptor.usage = MTLTextureUsageRenderTarget;
  target_descriptor.storageMode = MTLStorageModeShared;
  const id<MTLTexture> target = [device newTextureWithDescriptor:target_descriptor];
  const id<MTLTexture> atlas = [device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:1 height:1 mipmapped:NO]];
  constexpr unsigned char full_coverage = 255;
  [atlas replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&full_coverage bytesPerRow:1];
  auto *const pass = [MTLRenderPassDescriptor new];
  auto *const color = pass.colorAttachments[0];
  const auto background = vector(request[@"background"]);
  color.texture = target;
  color.loadAction = MTLLoadActionClear;
  color.storeAction = MTLStoreActionStore;
  color.clearColor = MTLClearColorMake(background.x, background.y, background.z, background.w);
  const id<MTLCommandQueue> queue = [device newCommandQueue];
  const id<MTLCommandBuffer> command = [queue commandBuffer];
  const id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:pipeline(device, source)];
  const id<MTLBuffer> buffer = [device newBufferWithBytes:quads.data() length:quads.size() * sizeof(Quad) options:MTLResourceStorageModeShared];
  const simd_float2 viewport{static_cast<float>(width), static_cast<float>(height)};
  [encoder setVertexBuffer:buffer offset:0 atIndex:0];
  [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:1];
  constexpr NSUInteger image_bindings = 11;
  for (NSUInteger index = 0; index < image_bindings; ++index) {
    [encoder setFragmentTexture:atlas atIndex:index];
  }

  constexpr NSUInteger triangle_vertices = 6;
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:triangle_vertices instanceCount:quads.size()];
  [encoder endEncoding];
  [command commit];
  [command waitUntilCompleted];
  require(command.status == MTLCommandBufferStatusCompleted, command.error.description);
  save(target, output);
}

}

int main(int argc, const char *argv[]) try {
  @autoreleasepool {
    constexpr int expected_arguments = 4;
    require(argc == expected_arguments, @"usage: rounded-rectangle-reference quad.metal cases.json output.png");
    NSError *error = nil;
    NSString *const source = [NSString stringWithContentsOfFile:argument(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    require(source != nil, error.description);
    NSData *const data = [NSData dataWithContentsOfFile:argument(argv[2])];
    require(data != nil, @"Could not read the reference cases");
    NSDictionary *const request = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    require(request != nil, error.description);
    const id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, @"No Metal device is available");
    render(device, source, request, argument(argv[3]));
  }

  return EXIT_SUCCESS;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return EXIT_FAILURE;
}
