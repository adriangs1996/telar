// Test-only Vulkan timing. Compile as an LD_PRELOAD library; production is unchanged.
// TELAR_LINUX_SLOT_PROBE=/tmp/frames.json LD_PRELOAD=/tmp/probe.so telar gui ...
#define _GNU_SOURCE
#include <dlfcn.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

enum { MAX_FRAMES = 8192, MAX_EVENTS = 131072 };
typedef struct {
    uint64_t acquire_begin, acquire_end, encode_begin, resources_end, encode_end;
    uint64_t submit_begin, submit_end, present_begin, present_end, fence_begin, fence_end;
    uint64_t present_fence_wait_ns, gpu_ticks;
    uint64_t allocated_bytes, atlas_bytes;
    uint32_t width, height, quads, image;
    int acquired, submitted, presented, completed;
    VkFence fence;
} frame_sample;

typedef struct {
    uint64_t time, token, detail;
    uint32_t kind;
} native_event;

static const char *output_path;
static frame_sample frames[MAX_FRAMES];
static native_event events[MAX_EVENTS];
static atomic_uint frame_count, event_count;
static _Thread_local frame_sample *active;
static VkDevice measured_device;
static VkQueryPool queries;
static PFN_vkCmdResetQueryPool reset_queries;
static PFN_vkCmdWriteTimestamp2 write_timestamp;
static PFN_vkGetQueryPoolResults read_queries;
static bool timestamp_queries_enabled;
static bool timestamp_queries_requested = true;
static float timestamp_period;
static uint32_t timestamp_bits, width, height, present_mode, image_count;
static uint64_t gpu_allocated_bytes, gpu_allocation_count;
static char device_name[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];

static uint64_t now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000000000 + value.tv_nsec;
}

static void *resolve(const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    if (symbol == NULL) {
        fprintf(stderr, "linux slot probe: missing %s\n", name);
        abort();
    }
    return symbol;
}

#define NEXT(name) static PFN_##name next; if (!next) { next = (PFN_##name)resolve(#name); }

// Instrumented copies of window.c/frame_worker.c call this bounded, allocation-free hook.
// Kind 0 is flags/deadline; 1/2 render; 3 enqueue; 4 complete; 5/6 worker; 7 shutdown.
void telar_slot_probe_event(uint32_t kind, uint64_t token, uint64_t detail) {
    if (output_path == NULL) {
        return;
    }
    unsigned index = atomic_fetch_add_explicit(&event_count, 1, memory_order_relaxed);
    if (index < MAX_EVENTS) {
        events[index] = (native_event){now_ns(), token, detail, kind};
    }
}

__attribute__((constructor)) static void initialize(void) {
    output_path = getenv("TELAR_LINUX_SLOT_PROBE");
    const char *requested = getenv("TELAR_LINUX_SLOT_TIMESTAMPS");
    timestamp_queries_requested = requested == NULL || strcmp(requested, "0") != 0;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo *info,
                                              const VkAllocationCallbacks *allocation, VkDevice *device) {
    NEXT(vkCreateDevice);
    VkResult result = next(physical, info, allocation, device);
    if (result != VK_SUCCESS || output_path == NULL) {
        return result;
    }
    measured_device = *device;
    PFN_vkGetPhysicalDeviceProperties properties_fn = resolve("vkGetPhysicalDeviceProperties");
    PFN_vkGetPhysicalDeviceQueueFamilyProperties families_fn = resolve("vkGetPhysicalDeviceQueueFamilyProperties");
    VkPhysicalDeviceProperties properties;
    properties_fn(physical, &properties);
    memcpy(device_name, properties.deviceName, sizeof device_name);
    timestamp_period = properties.limits.timestampPeriod;
    VkQueueFamilyProperties families[128];
    uint32_t count = 128;
    families_fn(physical, &count, families);
    uint32_t family = info->pQueueCreateInfos[0].queueFamilyIndex;
    if (family < count) {
        timestamp_bits = families[family].timestampValidBits;
    }
    if (timestamp_bits && timestamp_queries_requested) {
        VkQueryPoolCreateInfo query_info = {.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                                            .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2};
        PFN_vkCreateQueryPool create = resolve("vkCreateQueryPool");
        if (create(*device, &query_info, NULL, &queries) != VK_SUCCESS) {
            queries = VK_NULL_HANDLE;
        }
        timestamp_queries_enabled = queries != VK_NULL_HANDLE;
        reset_queries = resolve("vkCmdResetQueryPool");
        write_timestamp = resolve("vkCmdWriteTimestamp2");
        read_queries = resolve("vkGetQueryPoolResults");
    }
    return result;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyDevice(VkDevice device, const VkAllocationCallbacks *allocation) {
    NEXT(vkDestroyDevice);
    if (device == measured_device && queries) {
        PFN_vkDestroyQueryPool destroy = resolve("vkDestroyQueryPool");
        destroy(device, queries, NULL);
        queries = VK_NULL_HANDLE;
    }
    next(device, allocation);
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *info,
                                                    const VkAllocationCallbacks *allocation, VkSwapchainKHR *swapchain) {
    NEXT(vkCreateSwapchainKHR);
    VkResult result = next(device, info, allocation, swapchain);
    if (result == VK_SUCCESS && output_path) {
        width = info->imageExtent.width;
        height = info->imageExtent.height;
        present_mode = info->presentMode;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetSwapchainImagesKHR(VkDevice device, VkSwapchainKHR swapchain,
                                                       uint32_t *count, VkImage *images) {
    NEXT(vkGetSwapchainImagesKHR);
    VkResult result = next(device, swapchain, count, images);
    if (result == VK_SUCCESS && output_path) {
        image_count = *count;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                                                    VkSemaphore semaphore, VkFence fence, uint32_t *index) {
    NEXT(vkAcquireNextImageKHR);
    if (output_path) {
        unsigned slot = atomic_fetch_add_explicit(&frame_count, 1, memory_order_relaxed);
        active = slot < MAX_FRAMES ? &frames[slot] : NULL;
        if (active) {
            active->width = width;
            active->height = height;
            active->acquire_begin = now_ns();
        }
    }
    VkResult result = next(device, swapchain, timeout, semaphore, fence, index);
    if (active) {
        active->acquire_end = now_ns();
        active->acquired = result;
        if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) {
            active->image = *index;
        }
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer commands, const VkCommandBufferBeginInfo *info) {
    NEXT(vkBeginCommandBuffer);
    if (active) {
        active->encode_begin = now_ns();
    }
    VkResult result = next(commands, info);
    if (active && queries && result == VK_SUCCESS) {
        // The production backend has one slot and reads these before its reuse.
        reset_queries(commands, queries, 0, 2);
        write_timestamp(commands, VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, queries, 0);
    }
    return result;
}

VKAPI_ATTR void VKAPI_CALL vkCmdBeginRendering(VkCommandBuffer commands, const VkRenderingInfo *info) {
    NEXT(vkCmdBeginRendering);
    if (active) {
        active->resources_end = now_ns();
    }
    next(commands, info);
}

VKAPI_ATTR void VKAPI_CALL vkCmdDraw(VkCommandBuffer commands, uint32_t vertices, uint32_t instances,
                                     uint32_t first_vertex, uint32_t first_instance) {
    NEXT(vkCmdDraw);
    if (active) {
        active->quads += instances;
    }
    next(commands, vertices, instances, first_vertex, first_instance);
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBufferToImage(VkCommandBuffer commands, VkBuffer source, VkImage target,
                                                 VkImageLayout layout, uint32_t count, const VkBufferImageCopy *regions) {
    NEXT(vkCmdCopyBufferToImage);
    if (active) {
        for (uint32_t i = 0; i < count; i++) {
            active->atlas_bytes += (uint64_t)regions[i].imageExtent.width * regions[i].imageExtent.height;
        }
    }
    next(commands, source, target, layout, count, regions);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer commands) {
    NEXT(vkEndCommandBuffer);
    if (active && queries) {
        write_timestamp(commands, VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, queries, 1);
    }
    VkResult result = next(commands);
    if (active) {
        active->encode_end = now_ns();
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit2(VkQueue queue, uint32_t count, const VkSubmitInfo2 *submits, VkFence fence) {
    NEXT(vkQueueSubmit2);
    if (active) {
        active->submit_begin = now_ns();
        active->fence = fence;
    }
    VkResult result = next(queue, count, submits, fence);
    if (active) {
        active->submit_end = now_ns();
        active->submitted = result;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *info) {
    NEXT(vkQueuePresentKHR);
    if (active) {
        active->present_begin = now_ns();
    }
    VkResult result = next(queue, info);
    if (active) {
        active->present_end = now_ns();
        active->presented = result;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice device, uint32_t count, const VkFence *fences,
                                              VkBool32 all, uint64_t timeout) {
    NEXT(vkWaitForFences);
    uint64_t begin = now_ns();
    VkResult result = next(device, count, fences, all, timeout);
    uint64_t end = now_ns();
    if (active && count == 1 && active->fence == fences[0]) {
        active->fence_begin = begin;
        active->fence_end = end;
        active->completed = result;
        if (queries && result == VK_SUCCESS) {
            uint64_t values[2];
            if (read_queries(device, queries, 0, 2, sizeof values, values, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT) == VK_SUCCESS) {
                uint64_t mask = timestamp_bits == 64 ? UINT64_MAX : (UINT64_C(1) << timestamp_bits) - 1;
                active->gpu_ticks = (values[1] - values[0]) & mask;
            }
        }
        active = NULL;
    } else if (active) {
        active->present_fence_wait_ns += end - begin;
    }
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info,
                                                const VkAllocationCallbacks *allocation, VkDeviceMemory *memory) {
    NEXT(vkAllocateMemory);
    VkResult result = next(device, info, allocation, memory);
    if (output_path && result == VK_SUCCESS) {
        gpu_allocated_bytes += info->allocationSize;
        gpu_allocation_count++;
        if (active) {
            active->allocated_bytes += info->allocationSize;
        }
    }
    return result;
}

__attribute__((destructor)) static void finish(void) {
    if (output_path == NULL) {
        return;
    }
    FILE *file = fopen(output_path, "w");
    if (file == NULL) {
        return;
    }
    unsigned total = atomic_load(&frame_count), total_events = atomic_load(&event_count);
    fprintf(file, "{\"schema\":1,\"device\":\"%s\",\"timestamp_period_ns\":%.9g,\"timestamp_bits\":%u,"
                  "\"timestamp_queries_enabled\":%s,\"present_mode\":%u,\"swapchain_images\":%u,\"gpu_allocated_bytes\":%" PRIu64 ","
                  "\"gpu_allocation_count\":%" PRIu64 ",\"frame_overflow\":%u,\"event_overflow\":%u,\"frames\":[",
            device_name, timestamp_period, timestamp_bits, timestamp_queries_enabled ? "true" : "false",
            present_mode, image_count, gpu_allocated_bytes,
            gpu_allocation_count, total > MAX_FRAMES ? total - MAX_FRAMES : 0,
            total_events > MAX_EVENTS ? total_events - MAX_EVENTS : 0);
    for (unsigned i = 0; i < total && i < MAX_FRAMES; i++) {
        const frame_sample *s = &frames[i];
        fprintf(file, "%s{\"acquire_begin\":%" PRIu64 ",\"acquire_end\":%" PRIu64 ",\"encode_begin\":%" PRIu64
                      ",\"resources_end\":%" PRIu64 ",\"encode_end\":%" PRIu64 ",\"submit_begin\":%" PRIu64
                      ",\"submit_end\":%" PRIu64 ",\"present_begin\":%" PRIu64 ",\"present_end\":%" PRIu64
                      ",\"fence_begin\":%" PRIu64 ",\"fence_end\":%" PRIu64 ",\"present_fence_wait_ns\":%" PRIu64
                      ",\"gpu_ticks\":%" PRIu64 ",\"allocated_bytes\":%" PRIu64 ",\"atlas_bytes\":%" PRIu64
                      ",\"width\":%u,\"height\":%u,\"quads\":%u,\"image\":%u,\"acquired\":%d,\"submitted\":%d,"
                      "\"presented\":%d,\"completed\":%d}", i ? "," : "", s->acquire_begin, s->acquire_end,
                s->encode_begin, s->resources_end, s->encode_end, s->submit_begin, s->submit_end, s->present_begin,
                s->present_end, s->fence_begin, s->fence_end, s->present_fence_wait_ns, s->gpu_ticks,
                s->allocated_bytes, s->atlas_bytes, s->width, s->height, s->quads, s->image, s->acquired,
                s->submitted, s->presented, s->completed);
    }
    fputs("],\"events\":[", file);
    for (unsigned i = 0; i < total_events && i < MAX_EVENTS; i++) {
        const native_event *event = &events[i];
        fprintf(file, "%s[%u,%" PRIu64 ",%" PRIu64 ",%" PRIu64 "]", i ? "," : "", event->kind,
                event->time, event->token, event->detail);
    }
    fputs("]}\n", file);
    fclose(file);
}
