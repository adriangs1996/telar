#include "vulkan_resources.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    VkBuffer handle;
    VkDeviceMemory memory;
    VkDeviceSize capacity;
    void *mapped;
} mapped_buffer;

struct telar_vulkan_resources {
    const telar_vulkan_device *gpu;
    telar_vulkan_pipeline *pipeline;
    mapped_buffer quads, staging;
    VkImage atlas;
    VkDeviceMemory atlas_memory;
    VkImageView atlas_view;
    uint32_t atlas_side, atlas_version;
    bool atlas_uploaded;
};

static void destroy_buffer(VkDevice device, mapped_buffer *buffer) {
    if (buffer->mapped) {
        vkUnmapMemory(device, buffer->memory);
    }
    if (buffer->handle) {
        vkDestroyBuffer(device, buffer->handle, NULL);
    }
    if (buffer->memory) {
        vkFreeMemory(device, buffer->memory, NULL);
    }
    memset(buffer, 0, sizeof *buffer);
}

typedef struct {
    VkDeviceSize size;
    VkBufferUsageFlags usage;
} buffer_request;

static bool ensure_buffer(const telar_vulkan_device *gpu, mapped_buffer *buffer, buffer_request request) {
    if (buffer->capacity >= request.size) {
        return true;
    }
    mapped_buffer next = {0};
    VkDeviceSize capacity = 4096;
    while (capacity < request.size) {
        capacity *= 2;
    }
    if (request.usage == VK_BUFFER_USAGE_STORAGE_BUFFER_BIT && capacity > gpu->limits.maxStorageBufferRange) {
        capacity = request.size;
    }
    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = capacity,
        .usage = request.usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_TRY(vkCreateBuffer(gpu->device, &info, NULL, &next.handle));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(gpu->device, next.handle, &requirements);
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex =
            telar_vulkan_memory_type(gpu, requirements.memoryTypeBits,
                                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    if (allocate.memoryTypeIndex == UINT32_MAX ||
        vkAllocateMemory(gpu->device, &allocate, NULL, &next.memory) != VK_SUCCESS ||
        vkBindBufferMemory(gpu->device, next.handle, next.memory, 0) != VK_SUCCESS ||
        vkMapMemory(gpu->device, next.memory, 0, capacity, 0, &next.mapped) != VK_SUCCESS) {
        destroy_buffer(gpu->device, &next);
        return false;
    }
    next.capacity = capacity;
    destroy_buffer(gpu->device, buffer);
    *buffer = next;
    return true;
}

static void destroy_atlas(telar_vulkan_resources *self) {
    VkDevice device = self->gpu->device;
    if (self->atlas_view) {
        vkDestroyImageView(device, self->atlas_view, NULL);
    }
    if (self->atlas) {
        vkDestroyImage(device, self->atlas, NULL);
    }
    if (self->atlas_memory) {
        vkFreeMemory(device, self->atlas_memory, NULL);
    }
    self->atlas_view = VK_NULL_HANDLE;
    self->atlas = VK_NULL_HANDLE;
    self->atlas_memory = VK_NULL_HANDLE;
    self->atlas_side = 0;
    self->atlas_uploaded = false;
}

static bool ensure_atlas(telar_vulkan_resources *self, uint32_t side) {
    if (self->atlas_side == side) {
        return true;
    }
    destroy_atlas(self);
    VkDevice device = self->gpu->device;
    VkImageCreateInfo image = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8_UNORM,
        .extent = {side, side, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_TRY(vkCreateImage(device, &image, NULL, &self->atlas));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(device, self->atlas, &requirements);
    uint32_t type =
        telar_vulkan_memory_type(self->gpu, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (type == UINT32_MAX) {
        type = telar_vulkan_memory_type(self->gpu, requirements.memoryTypeBits, 0);
    }
    if (type == UINT32_MAX) {
        return false;
    }
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type,
    };
    VK_TRY(vkAllocateMemory(device, &allocate, NULL, &self->atlas_memory));
    VK_TRY(vkBindImageMemory(device, self->atlas, self->atlas_memory, 0));
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self->atlas,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VK_TRY(vkCreateImageView(device, &view, NULL, &self->atlas_view));
    if (!ensure_buffer(self->gpu, &self->staging,
                       (buffer_request){(VkDeviceSize)side * side, VK_BUFFER_USAGE_TRANSFER_SRC_BIT})) {
        return false;
    }
    VkDescriptorImageInfo binding = {self->pipeline->sampler, self->atlas_view,
                                     VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self->pipeline->descriptors,
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &binding,
    };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
    self->atlas_side = side;
    return true;
}

static void upload_atlas(telar_vulkan_resources *self, VkCommandBuffer commands, const telar_gui_frame *frame) {
    if (self->atlas_uploaded && self->atlas_version == frame->atlas_version) {
        return;
    }
    memcpy(self->staging.mapped, frame->atlas, (size_t)frame->atlas_side * frame->atlas_side);
    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = self->atlas_uploaded ? VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_2_NONE,
        .srcAccessMask = self->atlas_uploaded ? VK_ACCESS_2_SHADER_SAMPLED_READ_BIT : 0,
        .dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = self->atlas_uploaded ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = self->atlas,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VkDependencyInfo dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };
    vkCmdPipelineBarrier2(commands, &dependency);
    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {frame->atlas_side, frame->atlas_side, 1},
    };
    vkCmdCopyBufferToImage(commands, self->staging.handle, self->atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
                           &region);
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT;
    barrier.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier2(commands, &dependency);
    self->atlas_version = frame->atlas_version;
    self->atlas_uploaded = true;
}

telar_vulkan_resources *telar_vulkan_resources_create(const telar_vulkan_device *gpu, telar_vulkan_pipeline *pipeline) {
    telar_vulkan_resources *self = calloc(1, sizeof *self);
    if (self) {
        self->gpu = gpu;
        self->pipeline = pipeline;
    }
    return self;
}

bool telar_vulkan_resources_prepare(telar_vulkan_resources *self, VkCommandBuffer commands,
                                    const telar_gui_frame *frame) {
    if (frame->quad_count == 0) {
        return true;
    }
    VkDeviceSize bytes = (VkDeviceSize)frame->quad_count * sizeof(telar_gui_quad);
    if (!frame->quads || !frame->atlas || !frame->atlas_side ||
        frame->atlas_side > self->gpu->limits.maxImageDimension2D || bytes > self->gpu->limits.maxStorageBufferRange) {
        return false;
    }
    VkBuffer previous = self->quads.handle;
    if (!ensure_buffer(self->gpu, &self->quads, (buffer_request){bytes, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT})) {
        return false;
    }
    if (previous != self->quads.handle) {
        VkDescriptorBufferInfo binding = {self->quads.handle, 0, self->quads.capacity};
        VkWriteDescriptorSet write = {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self->pipeline->descriptors,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &binding,
        };
        vkUpdateDescriptorSets(self->gpu->device, 1, &write, 0, NULL);
    }
    memcpy(self->quads.mapped, frame->quads, (size_t)bytes);
    if (!ensure_atlas(self, frame->atlas_side)) {
        return false;
    }
    upload_atlas(self, commands, frame);
    return true;
}

void telar_vulkan_resources_destroy(telar_vulkan_resources *self) {
    if (!self) {
        return;
    }
    destroy_atlas(self);
    destroy_buffer(self->gpu->device, &self->quads);
    destroy_buffer(self->gpu->device, &self->staging);
    free(self);
}
