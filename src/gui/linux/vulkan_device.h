#pragma once
#define VK_USE_PLATFORM_WAYLAND_KHR
#include <stdbool.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

// Internal Vulkan ownership. Only the renderer assembles these components.
typedef struct {
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical;
    uint32_t queue_family;
    VkDevice device;
    VkQueue queue;
    VkPhysicalDeviceMemoryProperties memory;
    VkPhysicalDeviceLimits limits;
} telar_vulkan_device;

bool telar_vulkan_device_init(telar_vulkan_device *self, struct wl_display *display, struct wl_surface *surface);
void telar_vulkan_device_deinit(telar_vulkan_device *self);
uint32_t telar_vulkan_memory_type(const telar_vulkan_device *self, uint32_t bits, VkMemoryPropertyFlags wanted);

#define VK_TRY(step)                                                                                                   \
    do {                                                                                                               \
        VkResult result_ = (step);                                                                                     \
        if (result_ != VK_SUCCESS) {                                                                                   \
            fprintf(stderr, "telar gui: %s failed: %d\n", #step, (int)result_);                                        \
            return false;                                                                                              \
        }                                                                                                              \
    } while (0)
