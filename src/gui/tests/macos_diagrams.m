#import "../macos/TelarMetalRenderer.h"
#import <objc/runtime.h>
#include "../native/diagram_textures.h"
#include <assert.h>
#include <string.h>

// Inspect the retained texture slots without adding production test APIs.
@interface TelarMetalRenderer (DiagramTest)
- (BOOL)uploadDiagrams:(const telar_gui_frame *)frame;
@end

static id<MTLTexture> image_at(TelarMetalRenderer *renderer, unsigned slot) {
    Ivar field = class_getInstanceVariable(TelarMetalRenderer.class, "diagrams");
    assert(field && slot < TELAR_GUI_DIAGRAM_SLOTS);
    const uint8_t *storage = (__bridge const void *)renderer;
    void *image = *(void *const *)(storage + ivar_getOffset(field) + slot * sizeof(id));
    return (__bridge id<MTLTexture>)image;
}

static void check_pixel(id<MTLTexture> image, const uint8_t *wanted) {
    uint8_t actual[4];
    [image getBytes:actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    assert(memcmp(actual, wanted, 4) == 0);
}

int telar_test_diagrams(void) {
    _Static_assert(sizeof(telar_gui_diagram_texture) == 24, "diagram ABI");
    _Static_assert(offsetof(telar_gui_diagram_texture, version) == 16, "diagram version ABI");
    _Static_assert(offsetof(telar_gui_frame, diagrams) == 56, "frame diagram ABI");
    _Static_assert(sizeof(telar_gui_frame) == 272, "frame ABI");
    uint8_t red[32], green[32];
    for (unsigned i = 0; i < 8; i++) {
        memcpy(red + i * 4, (uint8_t[]){128, 0, 0, 128}, 4);
        memcpy(green + i * 4, (uint8_t[]){0, 255, 0, 255}, 4);
    }
    telar_gui_frame frame = {0};
    assert(telar_gui_diagrams_valid(&frame, 4096));
    frame.diagrams[0] = (telar_gui_diagram_texture){red, 4096, 1024, 1};
    frame.diagrams[7] = frame.diagrams[0];
    assert(telar_gui_diagrams_valid(&frame, 4096));
    frame.diagrams[1] = (telar_gui_diagram_texture){red, 1, 1, 1};
    assert(!telar_gui_diagrams_valid(&frame, 4096));
    frame.diagrams[1] = (telar_gui_diagram_texture){0};
    frame.diagrams[0].height++;
    assert(!telar_gui_diagrams_valid(&frame, 4096));
    frame.diagrams[0] = (telar_gui_diagram_texture){0};
    frame.diagrams[7] = (telar_gui_diagram_texture){red, 4, 2, UINT64_C(0x100000001)};
    assert(!telar_gui_diagrams_valid(&frame, 3));
    frame.diagrams[0].version = 1;
    assert(!telar_gui_diagrams_valid(&frame, 4096));
    frame.diagrams[0] = (telar_gui_diagram_texture){0};
    assert(telar_gui_diagrams_valid(&frame, 4096));

    TelarMetalRenderer *renderer = [[TelarMetalRenderer alloc] initWithCompletion:^(uint64_t token, BOOL success) {
        (void)token;
        (void)success;
    }];
    assert(renderer);
    assert([renderer uploadDiagrams:&frame]);
    id<MTLTexture> first = image_at(renderer, 7);
    assert(first && first.width == 4 && first.height == 2 && !image_at(renderer, 0));
    check_pixel(first, red);
    // Version identity, not pointer identity, determines whether bytes upload.
    frame.diagrams[7].pixels = green;
    assert([renderer uploadDiagrams:&frame]);
    assert(first == image_at(renderer, 7));
    check_pixel(first, red);
    frame.diagrams[7].version = 1;
    assert([renderer uploadDiagrams:&frame]);
    assert(first == image_at(renderer, 7));
    check_pixel(first, green);
    frame.diagrams[0] = frame.diagrams[7];
    frame.diagrams[7].width = 2;
    frame.diagrams[7].height = 4;
    assert([renderer uploadDiagrams:&frame]);
    assert(first != image_at(renderer, 7));
    assert(image_at(renderer, 7).width == 2 && image_at(renderer, 7).height == 4);
    check_pixel(image_at(renderer, 0), green);
    check_pixel(image_at(renderer, 7), green);
    memset(frame.diagrams, 0, sizeof frame.diagrams);
    assert([renderer uploadDiagrams:&frame]);
    assert(!image_at(renderer, 0) && !image_at(renderer, 7));
    // The same content version is uploaded again after a slot was cleared.
    frame.diagrams[7] = (telar_gui_diagram_texture){red, 4, 2, 1};
    assert([renderer uploadDiagrams:&frame]);
    check_pixel(image_at(renderer, 7), red);
    [renderer shutdown];
    return 0;
}
