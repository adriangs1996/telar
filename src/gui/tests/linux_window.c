#define _POSIX_C_SOURCE 200809L
#include "../linux/vulkan_device.h"
#include "../native/telar_gui.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <math.h>

static bool invalid_frame_test;
static bool deferred;
static atomic_uint alpha_checks;

VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *info,
                                                    const VkAllocationCallbacks *allocator, VkSwapchainKHR *swapchain) {
    if (info->compositeAlpha != VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR &&
        info->compositeAlpha != VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    PFN_vkCreateSwapchainKHR next = (PFN_vkCreateSwapchainKHR)dlsym(RTLD_NEXT, "vkCreateSwapchainKHR");
    return next(device, info, allocator, swapchain);
}

VKAPI_ATTR void VKAPI_CALL vkCmdBeginRendering(VkCommandBuffer commands, const VkRenderingInfo *info) {
    const float *color = info->pColorAttachments[0].clearValue.color.float32;
    if (fabsf(color[0] - .05f * color[3]) < .0001f &&
        fabsf(color[1] - .08f * color[3]) < .0001f &&
        fabsf(color[2] - .12f * color[3]) < .0001f) {
        atomic_fetch_add(&alpha_checks, 1);
    }
    PFN_vkCmdBeginRendering next = (PFN_vkCmdBeginRendering)dlsym(RTLD_NEXT, "vkCmdBeginRendering");
    next(commands, info);
}

static struct {
    int wake[2];
    atomic_uint painted, delivered, completed, retries, failures;
    atomic_uint cursor_shape, cursor_observed, cursor_queries;
    atomic_uint timer_remaining, timer_wakes;
    atomic_llong timer_deadline_ns;
    atomic_bool requested, closing;
    uint8_t atlas[4];
    uint8_t sprites[16];
    telar_gui_quad quads[7];
} state;

// Test-only interposition exercises retry paths against the real Vulkan backend.
VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                                                     VkSemaphore semaphore, VkFence fence, uint32_t *index) {
    static bool injected;
    if (!invalid_frame_test && !injected) {
        injected = true;
        return VK_ERROR_OUT_OF_DATE_KHR;
    }
    PFN_vkAcquireNextImageKHR next = (PFN_vkAcquireNextImageKHR)dlsym(RTLD_NEXT, "vkAcquireNextImageKHR");
    return next(device, swapchain, timeout, semaphore, fence, index);
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *present) {
    static bool injected;
    PFN_vkQueuePresentKHR next = (PFN_vkQueuePresentKHR)dlsym(RTLD_NEXT, "vkQueuePresentKHR");
    VkResult result = next(queue, present);
    if (!invalid_frame_test && !injected && result == VK_SUCCESS) {
        injected = true;
        return VK_ERROR_OUT_OF_DATE_KHR;
    }
    return result;
}

static void pause_ms(unsigned milliseconds) {
    struct timespec delay = {milliseconds / 1000, (long)(milliseconds % 1000) * 1000000};
    nanosleep(&delay, NULL);
}

static int64_t now_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

static bool await_delivery(unsigned wanted) {
    for (unsigned i = 0; i < 500; i++) {
        if (atomic_load(&state.delivered) >= wanted) {
            return true;
        }
        pause_ms(10);
    }
    atomic_fetch_add(&state.failures, 1);
    return false;
}

static void *exercise(void *unused) {
    (void)unused;
    if (!await_delivery(1)) {
        goto close;
    }
    for (unsigned i = 0; i < 12; i++) {
        unsigned before = atomic_load(&state.delivered);
        atomic_store(&state.requested, true);
        // Wake traffic must fold into pending work, not a queue of 100 frames.
        for (unsigned j = 0; j < 100; j++) {
            telar_gui_wake(state.wake[1]);
        }
        if (!await_delivery(before + 1)) {
            goto close;
        }
    }
    // After the initial wake, animation progresses solely through the host
    // deadline callback, then parks without a repeating timer or frame queue.
    unsigned before_timer = atomic_load(&state.delivered);
    atomic_store(&state.timer_remaining, 6);
    atomic_store(&state.requested, true);
    telar_gui_wake(state.wake[1]);
    if (!await_delivery(before_timer + 6)) {
        goto close;
    }
    if (atomic_load(&state.timer_wakes) != 5 || atomic_load(&state.timer_deadline_ns) != 0) {
        atomic_fetch_add(&state.failures, 1);
    }
    pause_ms(200);
    unsigned settled = atomic_load(&state.painted);
    atomic_store(&state.cursor_shape, 3);
    telar_gui_wake(state.wake[1]);
    for (unsigned i = 0; i < 500 && atomic_load(&state.cursor_observed) != 3; i++) {
        pause_ms(10);
    }
    if (atomic_load(&state.cursor_observed) != 3) {
        atomic_fetch_add(&state.failures, 1);
    }
    pause_ms(100);
    unsigned cursor_queries = atomic_load(&state.cursor_queries);
    pause_ms(300);
    if (cursor_queries != atomic_load(&state.cursor_queries)) {
        atomic_fetch_add(&state.failures, 1);
    }
    if (settled != atomic_load(&state.painted) || settled > 22) {
        atomic_fetch_add(&state.failures, 1);
    }
close:
    atomic_store(&state.closing, true);
    telar_gui_wake(state.wake[1]);
    return NULL;
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    (void)context;
    if (!invalid_frame_test && !deferred) {
        deferred = true;
        *frame = (telar_gui_frame){0};
        atomic_store(&state.requested, true);
        telar_gui_wake(state.wake[1]);
        return;
    }
    unsigned token = atomic_fetch_add(&state.painted, 1) + 1;
    if (!viewport.width || !viewport.height) {
        atomic_fetch_add(&state.failures, 1);
    }
    // Changing both pixels and atlas versions exercises retained resources and barriers.
    state.atlas[0] = 255;
    state.atlas[1] = token & 1 ? 64 : 192;
    state.atlas[2] = 128;
    state.atlas[3] = 255;
    state.quads[0] = (telar_gui_quad){
        .x = 20, .y = 30, .width = 200, .height = 100, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = .3f, .a = 1};
    state.quads[1] = (telar_gui_quad){
        .x = 40, .y = 50, .width = 40, .height = 60, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .b = 1, .a = .5f};
    // A rounded card and an inner ring exercise the signed-distance paths.
    state.quads[2] = (telar_gui_quad){
        .x = 40, .y = 140, .width = 200, .height = 100, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = .2f, .g = .4f, .b = .9f, .a = 1, .radius = 8};
    state.quads[3] = (telar_gui_quad){
        .x = 60, .y = 260, .width = 200, .height = 100, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .radius = 8, .border = 2, .border_r = 1, .border_g = .8f, .border_b = .2f, .border_a = 1};
    // A 2x2 premultiplied RGBA sprite page changes with the token like the atlas;
    // the fifth quad selects it through the shape's texture component.
    const uint8_t sprites[16] = {255, 0, 0, 255, 0, (uint8_t)(token & 1 ? 255 : 64), 0, 255, 0, 0, 255, 255, 128, 128, 128, 128};
    memcpy(state.sprites, sprites, sizeof sprites);
    state.quads[4] = (telar_gui_quad){
        .x = 300, .y = 30, .width = 64, .height = 64, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1, .a = 1, .texture = 1};
    *frame = (telar_gui_frame){.token = token,
                               .quads = state.quads,
                               .quad_count = 5,
                               .atlas = state.atlas,
                               .atlas_side = 2,
                               .atlas_version = token,
                               // Frames without sprites keep the previous page bound.
                               .sprites = token % 4 == 0 ? NULL : state.sprites,
                               .sprites_side = 2,
                               .sprites_version = token,
                               .background = {.05f, .08f, .12f, token % 2 ? .5f : 1},
                               .background_blur = token % 3 != 0};
    // Alternate retained content, replacement, and complete slot release.
    if (token % 3 != 0) {
        state.quads[5] = (telar_gui_quad){.x = 300, .y = 120, .width = 160, .height = 80,
            .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1, .a = 1, .texture = 2};
        state.quads[6] = state.quads[5];
        state.quads[6].y = 220;
        state.quads[6].texture = 9;
        frame->quad_count = 7;
        frame->diagrams[0] = (telar_gui_diagram_texture){state.sprites, 4, 1, 1};
        frame->diagrams[7] = (telar_gui_diagram_texture){state.sprites, 1, 4, UINT64_C(0x100000000) + token};
    }
    if (invalid_frame_test) {
        frame->atlas_side = 0;
    }
    if (atomic_load(&state.timer_remaining) != 0) {
        unsigned remaining = atomic_fetch_sub(&state.timer_remaining, 1);
        atomic_store(&state.timer_deadline_ns, remaining > 1 ? now_ns() + 16666667 : 0);
    }
}

static int pump(void *context) {
    (void)context;
    if (atomic_load(&state.closing)) {
        return -1;
    }
    bool requested = atomic_exchange(&state.requested, false);
    int64_t deadline = atomic_load(&state.timer_deadline_ns);
    if (deadline != 0 && now_ns() >= deadline) {
        atomic_store(&state.timer_deadline_ns, 0);
        atomic_fetch_add(&state.timer_wakes, 1);
        requested = true;
    }
    return requested;
}

static uint32_t wakeup_after(void *context) {
    (void)context;
    int64_t deadline = atomic_load(&state.timer_deadline_ns);
    if (deadline == 0) {
        return 0;
    }
    int64_t delay = deadline - now_ns();
    return delay <= 0 ? 1 : (uint32_t)((delay + 999999) / 1000000);
}

static uint32_t pointer_shape(void *context) {
    (void)context;
    atomic_fetch_add(&state.cursor_queries, 1);
    uint32_t shape = atomic_load(&state.cursor_shape);
    atomic_store(&state.cursor_observed, shape);
    return shape;
}

static void complete(void *context, uint64_t token, int success) {
    (void)context;
    unsigned expected = atomic_fetch_add(&state.completed, 1) + 1;
    if (token != expected) {
        atomic_fetch_add(&state.failures, 1);
    }
    if (invalid_frame_test) {
        if (success || token != 1) {
            atomic_fetch_add(&state.failures, 1);
        }
        return;
    }
    if (success) {
        atomic_fetch_add(&state.delivered, 1);
    } else if (token <= 2) {
        atomic_fetch_add(&state.retries, 1);
    } else {
        atomic_fetch_add(&state.failures, 1);
    }
}

static int input(void *context, telar_gui_input event) {
    (void)context;
    (void)event;
    return 1;
}

int main(int argc, char **argv) {
    (void)argv;
    invalid_frame_test = argc > 1;
    if (telar_gui_pipe(state.wake) != 0) {
        return 1;
    }
    pthread_t producer;
    if (!invalid_frame_test && pthread_create(&producer, NULL, exercise, NULL) != 0) {
        return 1;
    }
    telar_gui_callbacks callbacks = {
        .render = render, .pump = pump, .complete = complete, .input = input, .wake_fd = state.wake[0], .pointer_shape = pointer_shape, .wakeup_after = wakeup_after};
    int status = telar_gui_run("Telar Vulkan integration test", NULL, &callbacks);
    if (invalid_frame_test) {
        telar_gui_close_pipe(state.wake);
        bool passed = status == -1 && atomic_load(&state.completed) == 1 && atomic_load(&state.failures) == 0;
        printf("native Linux: rejected scene cleanup %s\n", passed ? "passed" : "failed");
        return !passed;
    }
    pthread_join(producer, NULL);
    telar_gui_close_pipe(state.wake);
    if (atomic_load(&state.retries) != 2) {
        atomic_fetch_add(&state.failures, 1);
    }
    if (atomic_load(&alpha_checks) < atomic_load(&state.delivered)) {
        atomic_fetch_add(&state.failures, 1);
    }
    unsigned failures = atomic_load(&state.failures);
    printf("native Linux: status=%d painted=%u delivered=%u retries=%u timer_wakes=%u failures=%u\n", status,
           atomic_load(&state.painted), atomic_load(&state.delivered), atomic_load(&state.retries), atomic_load(&state.timer_wakes), failures);
    return status != 0 || failures != 0;
}
