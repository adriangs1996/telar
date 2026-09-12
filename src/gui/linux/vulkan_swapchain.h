#pragma once
#include "../native/telar_gui.h"
#include "vulkan_device.h"

#define TELAR_SWAPCHAIN_IMAGES 8

typedef struct {
    VkImage image;
    VkImageView view;
    VkSemaphore finished;
    VkFence presented;
    bool pending;
} telar_vulkan_target;

typedef struct {
    const telar_vulkan_device *gpu;
    VkSwapchainKHR handle;
    VkFormat format;
    VkExtent2D extent;
    telar_gui_viewport requested;
    uint32_t count;
    telar_vulkan_target targets[TELAR_SWAPCHAIN_IMAGES];
    bool stale;
} telar_vulkan_swapchain;

// Caller has drained render work before rebuilding or destroying the swapchain.
bool telar_vulkan_swapchain_resize(telar_vulkan_swapchain *self, telar_gui_viewport viewport);
VkResult telar_vulkan_swapchain_acquire(telar_vulkan_swapchain *self, VkSemaphore ready, uint32_t *index);
VkResult telar_vulkan_swapchain_present(telar_vulkan_swapchain *self, uint32_t index);
void telar_vulkan_swapchain_deinit(telar_vulkan_swapchain *self);
