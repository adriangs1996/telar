#import "../macos/TelarMetalRenderer.h"
#import <objc/runtime.h>
#import <QuartzCore/CAMetalLayer.h>
#include <assert.h>
#include <string.h>

// Inspect the renderer's image textures without adding production test APIs.
static id<MTLTexture> image_at(TelarMetalRenderer *renderer, uint32_t handle) {
    Ivar field = class_getInstanceVariable(TelarMetalRenderer.class, "images");
    assert(field && handle >= 1 && handle <= TELAR_GUI_IMAGE_CAPACITY);
    const uint8_t *storage = (__bridge const void *)renderer;
    void *image = *(void *const *)(storage + ivar_getOffset(field) + (handle - 1) * sizeof(id));
    return (__bridge id<MTLTexture>)image;
}

static void read_texel(id<MTLTexture> texture, uint32_t x, uint32_t y, uint8_t *out) {
    [texture getBytes:out bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
}

// Spins the main run loop until `done` holds or a second passes.
static BOOL wait_until(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!done() && [deadline timeIntervalSinceNow] > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }

    return done();
}

static telar_gui_quad solid(float x, float width, const float *color) {
    const float uv = 0.5f / 1024.0f;
    return (telar_gui_quad){
        .x = x, .y = 0, .width = width, .height = 4,
        .u0 = uv, .v0 = uv, .u1 = uv, .v1 = uv,
        .r = color[0], .g = color[1], .b = color[2], .a = color[3],
    };
}

static telar_gui_quad image(float x, float width) {
    return (telar_gui_quad){
        .x = x, .y = 0, .width = width, .height = 4,
        .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1,
        .r = 1, .g = 1, .b = 1, .a = 1,
        .texture = TELAR_GUI_IMAGE_TEXTURE,
    };
}

int telar_test_images(void) {
    _Static_assert(sizeof(telar_gui_frame) == 328, "frame ABI");
    _Static_assert(offsetof(telar_gui_frame, image_uploads) == 280, "frame image ABI");
    _Static_assert(offsetof(telar_gui_frame, image_draw_count) == 320, "frame image draw ABI");
    _Static_assert(sizeof(telar_gui_image_upload) == 24, "image upload ABI");
    _Static_assert(sizeof(telar_gui_image_draw) == 8, "image draw ABI");

    __block uint32_t ready_mask = 0;
    __block uint32_t failed_mask = 0;
    __block uint32_t completions = 0;
    TelarMetalRenderer *renderer = [[TelarMetalRenderer alloc]
        initWithCompletion:^(uint64_t token, BOOL success) {
            (void)token;
            assert(success);
            completions++;
        }
        imageReady:^(uint32_t handle, BOOL success) {
            if (success) {
                ready_mask |= 1u << handle;
            } else {
                failed_mask |= 1u << handle;
            }
        }];
    assert(renderer);

    // Handle 1: RGB green, expanded to opaque RGBA. Handle 2: RGBA blue with
    // straight alpha, kept as sent. Handle 3: an unsupported layout fails.
    uint8_t green[4 * 4 * 3], blue[4 * 4 * 4];
    for (unsigned i = 0; i < 16; i++) {
        memcpy(green + i * 3, (uint8_t[]){0, 255, 0}, 3);
        memcpy(blue + i * 4, (uint8_t[]){0, 0, 255, 128}, 4);
    }

    telar_gui_image_upload uploads[] = {
        {green, 1, 4, 4, 3},
        {blue, 2, 4, 4, 4},
        {blue, 3, 4, 4, 2},
    };
    telar_gui_frame frame = {0};
    frame.image_uploads = uploads;
    frame.image_upload_count = 3;
    [renderer acceptImages:&frame];
    assert(failed_mask == 1u << 3);
    assert(wait_until(^BOOL { return ready_mask == ((1u << 1) | (1u << 2)); }));

    uint8_t texel[4];
    read_texel(image_at(renderer, 1), 3, 3, texel);
    assert(memcmp(texel, (uint8_t[]){0, 255, 0, 255}, 4) == 0);
    read_texel(image_at(renderer, 2), 0, 0, texel);
    assert(memcmp(texel, (uint8_t[]){0, 0, 255, 128}, 4) == 0);

    // One frame: a red background, then image 1 on the left half over it,
    // image 2 on the right half, then a white bar over image 2's left column.
    // Two textures in one frame and quad order both have to hold.
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = renderer.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.drawableSize = CGSizeMake(8, 4);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    assert(drawable);

    static uint8_t atlas[1024 * 1024];
    atlas[0] = 255;
    const float red[4] = {1, 0, 0, 1};
    const float white[4] = {1, 1, 1, 1};
    telar_gui_quad quads[] = {
        solid(0, 8, red),
        image(0, 4),
        image(4, 4),
        solid(4, 1, white),
    };
    telar_gui_image_draw draws[] = {{1, 1}, {2, 2}};
    memset(&frame, 0, sizeof frame);
    frame.token = 1;
    frame.quads = quads;
    frame.quad_count = 4;
    frame.atlas = atlas;
    frame.atlas_side = 1024;
    frame.atlas_version = 1;
    frame.background[3] = 1;
    frame.image_draws = draws;
    frame.image_draw_count = 2;
    [renderer acceptImages:&frame];
    assert([renderer renderFrame:&frame drawable:drawable]);
    assert(wait_until(^BOOL { return completions == 1; }));

    // BGRA target: green on the left, the white bar, then blue at half alpha
    // over red on the right.
    read_texel(drawable.texture, 1, 1, texel);
    assert(texel[0] == 0 && texel[1] == 255 && texel[2] == 0);
    read_texel(drawable.texture, 4, 1, texel);
    assert(texel[0] == 255 && texel[1] == 255 && texel[2] == 255);
    read_texel(drawable.texture, 6, 1, texel);
    assert(texel[0] >= 126 && texel[0] <= 130 && texel[1] == 0 && texel[2] >= 125 && texel[2] <= 129);

    // A released handle takes a new upload; a draw of an empty handle skips
    // only its own quad.
    uint32_t releases[] = {1};
    memset(&frame, 0, sizeof frame);
    frame.image_releases = releases;
    frame.image_release_count = 1;
    [renderer acceptImages:&frame];
    assert(image_at(renderer, 1) == nil);
    uploads[0] = (telar_gui_image_upload){blue, 1, 2, 8, 4};
    frame.image_releases = NULL;
    frame.image_release_count = 0;
    frame.image_uploads = uploads;
    frame.image_upload_count = 1;
    ready_mask = 0;
    [renderer acceptImages:&frame];
    assert(wait_until(^BOOL { return ready_mask == 1u << 1; }));
    assert(image_at(renderer, 1).width == 2 && image_at(renderer, 1).height == 8);

    [renderer shutdown];
    assert(image_at(renderer, 2) == nil);
    return 0;
}
