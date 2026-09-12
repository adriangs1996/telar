#include "renderer.h"
#include "vulkan_device.h"
#include "vulkan_pipeline.h"
#include "vulkan_resources.h"
#include "vulkan_swapchain.h"
#include <stdlib.h>

struct telar_renderer {
    telar_vulkan_device gpu;
    telar_vulkan_swapchain swapchain;
    telar_vulkan_pipeline pipeline;
    telar_vulkan_resources *resources;
    VkCommandPool pool;
    VkCommandBuffer commands;
    VkFence fence;
    VkSemaphore image_available;
};

static bool create_submission(telar_renderer *self) {
    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self->gpu.queue_family,
    };
    VK_TRY(vkCreateCommandPool(self->gpu.device, &pool, NULL, &self->pool));
    VkCommandBufferAllocateInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self->pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VK_TRY(vkAllocateCommandBuffers(self->gpu.device, &commands, &self->commands));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VK_TRY(vkCreateFence(self->gpu.device, &fence, NULL, &self->fence));
    VkSemaphoreCreateInfo semaphore = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VK_TRY(vkCreateSemaphore(self->gpu.device, &semaphore, NULL, &self->image_available));
    return true;
}

static bool resize(telar_renderer *self, telar_gui_viewport viewport) {
    if (!telar_vulkan_swapchain_resize(&self->swapchain, viewport)) {
        return false;
    }
    if (self->pipeline.pipeline && self->pipeline.format == self->swapchain.format) {
        return true;
    }
    telar_vulkan_resources_destroy(self->resources);
    self->resources = NULL;
    telar_vulkan_pipeline_deinit(&self->pipeline);
    if (!telar_vulkan_pipeline_init(&self->pipeline, self->gpu.device, self->swapchain.format)) {
        return false;
    }
    self->resources = telar_vulkan_resources_create(&self->gpu, &self->pipeline);
    return self->resources != NULL;
}

telar_renderer *telar_renderer_create(struct wl_display *display, struct wl_surface *surface,
                                      telar_gui_viewport viewport) {
    telar_renderer *self = calloc(1, sizeof *self);
    if (!self) {
        return NULL;
    }
    self->swapchain.gpu = &self->gpu;
    if (!telar_vulkan_device_init(&self->gpu, display, surface) || !create_submission(self) ||
        !resize(self, viewport)) {
        telar_renderer_destroy(self);
        return NULL;
    }
    return self;
}

static void attachment_barrier(telar_renderer *self, VkImage image, bool presenting) {
    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = presenting ? VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT : 0,
        .dstStageMask = presenting ? VK_PIPELINE_STAGE_2_NONE : VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = presenting ? 0 : VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = presenting ? VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = presenting ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VkDependencyInfo dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };
    vkCmdPipelineBarrier2(self->commands, &dependency);
}

static bool encode(telar_renderer *self, uint32_t index, const telar_gui_frame *frame) {
    VK_TRY(vkResetCommandBuffer(self->commands, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VK_TRY(vkBeginCommandBuffer(self->commands, &begin));
    if (!telar_vulkan_resources_prepare(self->resources, self->commands, frame)) {
        return false;
    }
    telar_vulkan_target *target = &self->swapchain.targets[index];
    attachment_barrier(self, target->image, false);
    VkRenderingAttachmentInfo color = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = target->view,
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue.color = {{frame->background[0], frame->background[1], frame->background[2], frame->background[3]}},
    };
    VkRenderingInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = {{0, 0}, self->swapchain.extent},
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color,
    };
    vkCmdBeginRendering(self->commands, &rendering);
    if (frame->quad_count) {
        float size[2] = {(float)self->swapchain.extent.width, (float)self->swapchain.extent.height};
        VkViewport viewport = {0, 0, size[0], size[1], 0, 1};
        VkRect2D scissor = {{0, 0}, self->swapchain.extent};
        vkCmdBindPipeline(self->commands, VK_PIPELINE_BIND_POINT_GRAPHICS, self->pipeline.pipeline);
        vkCmdSetViewport(self->commands, 0, 1, &viewport);
        vkCmdSetScissor(self->commands, 0, 1, &scissor);
        vkCmdBindDescriptorSets(self->commands, VK_PIPELINE_BIND_POINT_GRAPHICS, self->pipeline.layout, 0, 1,
                                &self->pipeline.descriptors, 0, NULL);
        vkCmdPushConstants(self->commands, self->pipeline.layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof size, size);
        vkCmdDraw(self->commands, 6, frame->quad_count, 0, 0);
    }
    vkCmdEndRendering(self->commands);
    attachment_barrier(self, target->image, true);
    VK_TRY(vkEndCommandBuffer(self->commands));
    return true;
}

static bool submit(telar_renderer *self, uint32_t index, bool draw) {
    VkSemaphoreSubmitInfo wait = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = self->image_available,
        .stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
    };
    VkSemaphoreSubmitInfo signal = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = self->swapchain.targets[index].finished,
        .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    };
    VkCommandBufferSubmitInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = self->commands,
    };
    VkSubmitInfo2 info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &wait,
        .commandBufferInfoCount = draw ? 1 : 0,
        .pCommandBufferInfos = &commands,
        .signalSemaphoreInfoCount = draw ? 1 : 0,
        .pSignalSemaphoreInfos = &signal,
    };
    VK_TRY(vkResetFences(self->gpu.device, 1, &self->fence));
    VK_TRY(vkQueueSubmit2(self->gpu.queue, 1, &info, self->fence));
    return true;
}

enum telar_render_result telar_renderer_draw(telar_renderer *self, telar_gui_viewport viewport,
                                             const telar_gui_frame *frame) {
    // The previous draw returned only after GPU completion; resources can be reused.
    if (!viewport.width || !viewport.height) {
        return TELAR_RENDER_RETRY;
    }
    if (!resize(self, viewport)) {
        return TELAR_RENDER_FAILED;
    }
    uint32_t index;
    VkResult acquired = telar_vulkan_swapchain_acquire(&self->swapchain, self->image_available, &index);
    if (acquired == VK_ERROR_OUT_OF_DATE_KHR || acquired == VK_TIMEOUT || acquired == VK_NOT_READY) {
        return TELAR_RENDER_RETRY;
    }
    if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR) {
        return TELAR_RENDER_FAILED;
    }
    if (!encode(self, index, frame) || !submit(self, index, true)) {
        // Even a rejected scene acquired an image. Consume acquisition before
        // teardown can destroy its semaphore; no scene is submitted.
        if (submit(self, index, false)) {
            vkWaitForFences(self->gpu.device, 1, &self->fence, VK_TRUE, UINT64_MAX);
        }
        return TELAR_RENDER_FAILED;
    }
    VkResult presented = telar_vulkan_swapchain_present(&self->swapchain, index);
    // Even a failed present must finish consuming the sealed scene before delivery.
    VkResult completed = vkWaitForFences(self->gpu.device, 1, &self->fence, VK_TRUE, UINT64_MAX);
    if (completed != VK_SUCCESS) {
        return TELAR_RENDER_FAILED;
    }
    if (presented == VK_ERROR_OUT_OF_DATE_KHR) {
        return TELAR_RENDER_RETRY;
    }
    return presented == VK_SUCCESS || presented == VK_SUBOPTIMAL_KHR ? TELAR_RENDER_DELIVERED : TELAR_RENDER_FAILED;
}

void telar_renderer_destroy(telar_renderer *self) {
    if (!self) {
        return;
    }
    if (self->gpu.device) {
        vkDeviceWaitIdle(self->gpu.device);
        telar_vulkan_swapchain_deinit(&self->swapchain);
        telar_vulkan_resources_destroy(self->resources);
        telar_vulkan_pipeline_deinit(&self->pipeline);
        if (self->image_available) {
            vkDestroySemaphore(self->gpu.device, self->image_available, NULL);
        }
        if (self->fence) {
            vkDestroyFence(self->gpu.device, self->fence, NULL);
        }
        if (self->pool) {
            vkDestroyCommandPool(self->gpu.device, self->pool, NULL);
        }
    }
    telar_vulkan_device_deinit(&self->gpu);
    free(self);
}
