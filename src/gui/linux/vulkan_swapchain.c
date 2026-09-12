#include "vulkan_swapchain.h"
#include <string.h>

void telar_vulkan_swapchain_deinit(telar_vulkan_swapchain *self) {
    VkDevice device = self->gpu->device;
    for (uint32_t i = 0; i < self->count; i++) {
        telar_vulkan_target *target = &self->targets[i];
        // A render fence cannot prove that presentation has released its resources.
        if (target->pending) {
            vkWaitForFences(device, 1, &target->presented, VK_TRUE, UINT64_MAX);
        }
        if (target->presented) {
            vkDestroyFence(device, target->presented, NULL);
        }
        if (target->finished) {
            vkDestroySemaphore(device, target->finished, NULL);
        }
        if (target->view) {
            vkDestroyImageView(device, target->view, NULL);
        }
    }
    if (self->handle) {
        vkDestroySwapchainKHR(device, self->handle, NULL);
    }
    memset(self->targets, 0, sizeof self->targets);
    self->handle = VK_NULL_HANDLE;
    self->count = 0;
}

static bool choose_format(telar_vulkan_swapchain *self, VkSurfaceFormatKHR *chosen) {
    uint32_t count = 0;
    VK_TRY(vkGetPhysicalDeviceSurfaceFormatsKHR(self->gpu->physical, self->gpu->surface, &count, NULL));
    if (count == 0 || count > 128) {
        return false;
    }
    VkSurfaceFormatKHR formats[128];
    VK_TRY(vkGetPhysicalDeviceSurfaceFormatsKHR(self->gpu->physical, self->gpu->surface, &count, formats));
    bool found = false;
    for (uint32_t i = 0; i < count; i++) {
        if (formats[i].colorSpace != VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            continue;
        }
        if (!found || formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) {
            *chosen = formats[i];
            found = true;
        }
    }
    if (found && chosen->format == VK_FORMAT_UNDEFINED) {
        chosen->format = VK_FORMAT_B8G8R8A8_UNORM;
    }
    return found;
}

static uint32_t bounded(uint32_t value, uint32_t low, uint32_t high) {
    return value < low ? low : value > high ? high : value;
}

bool telar_vulkan_swapchain_resize(telar_vulkan_swapchain *self, telar_gui_viewport viewport) {
    if (self->handle && !self->stale && self->requested.width == viewport.width &&
        self->requested.height == viewport.height) {
        return true;
    }
    VkSurfaceCapabilitiesKHR capabilities;
    VK_TRY(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self->gpu->physical, self->gpu->surface, &capabilities));
    VkSurfaceFormatKHR chosen;
    if (!choose_format(self, &chosen)) {
        return false;
    }
    VkExtent2D extent = capabilities.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = bounded(viewport.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
        extent.height =
            bounded(viewport.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
    }
    if (!extent.width || !extent.height) {
        return false;
    }
    uint32_t wanted = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount && wanted > capabilities.maxImageCount) {
        wanted = capabilities.maxImageCount;
    }
    if (wanted > TELAR_SWAPCHAIN_IMAGES) {
        return false;
    }
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    while (!(capabilities.supportedCompositeAlpha & alpha) && alpha <= VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) {
        alpha <<= 1;
    }
    if (!(capabilities.supportedCompositeAlpha & alpha)) {
        return false;
    }
    VkSwapchainCreateInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = self->gpu->surface,
        .minImageCount = wanted,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
        .oldSwapchain = self->handle,
    };
    VkSwapchainKHR handle;
    VK_TRY(vkCreateSwapchainKHR(self->gpu->device, &info, NULL, &handle));
    telar_vulkan_swapchain_deinit(self);
    self->handle = handle;
    self->format = chosen.format;
    self->extent = extent;
    self->requested = viewport;
    self->stale = false;
    uint32_t count = 0;
    VK_TRY(vkGetSwapchainImagesKHR(self->gpu->device, handle, &count, NULL));
    if (count == 0 || count > TELAR_SWAPCHAIN_IMAGES) {
        return false;
    }
    VkImage images[TELAR_SWAPCHAIN_IMAGES];
    VK_TRY(vkGetSwapchainImagesKHR(self->gpu->device, handle, &count, images));
    self->count = count;
    for (uint32_t i = 0; i < count; i++) {
        telar_vulkan_target *target = &self->targets[i];
        target->image = images[i];
        VkImageViewCreateInfo view = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = target->image,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = self->format,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        VK_TRY(vkCreateImageView(self->gpu->device, &view, NULL, &target->view));
        VkSemaphoreCreateInfo semaphore = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        VK_TRY(vkCreateSemaphore(self->gpu->device, &semaphore, NULL, &target->finished));
        VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        VK_TRY(vkCreateFence(self->gpu->device, &fence, NULL, &target->presented));
    }
    return true;
}

VkResult telar_vulkan_swapchain_acquire(telar_vulkan_swapchain *self, VkSemaphore ready, uint32_t *index) {
    // Bound the wait so closing a hidden window can join its worker.
    VkResult result = vkAcquireNextImageKHR(self->gpu->device, self->handle, 100000000, ready, VK_NULL_HANDLE, index);
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) {
        self->stale = true;
    }
    return result;
}

VkResult telar_vulkan_swapchain_present(telar_vulkan_swapchain *self, uint32_t index) {
    telar_vulkan_target *target = &self->targets[index];
    if (target->pending) {
        VkResult waited = vkWaitForFences(self->gpu->device, 1, &target->presented, VK_TRUE, UINT64_MAX);
        if (waited != VK_SUCCESS) {
            return waited;
        }
        target->pending = false;
        VkResult reset = vkResetFences(self->gpu->device, 1, &target->presented);
        if (reset != VK_SUCCESS) {
            return reset;
        }
    }
    VkSwapchainPresentFenceInfoEXT fence = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT,
        .swapchainCount = 1,
        .pFences = &target->presented,
    };
    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = &fence,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &target->finished,
        .swapchainCount = 1,
        .pSwapchains = &self->handle,
        .pImageIndices = &index,
    };
    VkResult result = vkQueuePresentKHR(self->gpu->queue, &present);
    // OUT_OF_DATE still enqueues the semaphore wait and presentation fence.
    target->pending = result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR || result == VK_ERROR_OUT_OF_DATE_KHR;
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) {
        self->stale = true;
    }
    return result;
}
