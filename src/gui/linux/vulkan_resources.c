#include "vulkan_resources.h"
#include <stdlib.h>
#include <string.h>
#include "../native/diagram_textures.h"

typedef struct {
    VkBuffer handle;
    VkDeviceMemory memory;
    VkDeviceSize capacity;
    void *mapped;
} mapped_buffer;

// One sampled rectangle with staging storage; glyph and sprite pages are square.
typedef struct {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    mapped_buffer staging;
    VkFormat format;
    uint32_t bytes_per_texel, binding;
    uint32_t width, height;
    uint64_t version;
    bool uploaded;
} gpu_texture;

struct telar_vulkan_resources {
    const telar_vulkan_device *gpu;
    telar_vulkan_pipeline *pipeline;
    mapped_buffer quads;
    gpu_texture atlas, sprites;
    gpu_texture diagrams[TELAR_GUI_DIAGRAM_SLOTS];
    bool sprites_bound;
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
    VkDeviceSize capacity = request.usage == VK_BUFFER_USAGE_TRANSFER_SRC_BIT ? request.size : 4096;
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

static void destroy_texture(telar_vulkan_resources *self, gpu_texture *texture) {
    VkDevice device = self->gpu->device;
    if (texture->view) {
        vkDestroyImageView(device, texture->view, NULL);
    }
    if (texture->image) {
        vkDestroyImage(device, texture->image, NULL);
    }
    if (texture->memory) {
        vkFreeMemory(device, texture->memory, NULL);
    }
    destroy_buffer(device, &texture->staging);
    texture->view = VK_NULL_HANDLE;
    texture->image = VK_NULL_HANDLE;
    texture->memory = VK_NULL_HANDLE;
    texture->width = texture->height = 0;
    texture->uploaded = false;
}

static void bind_texture(telar_vulkan_resources *self, uint32_t binding, VkImageView view, VkSampler sampler) {
    VkDescriptorImageInfo image = {sampler, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self->pipeline->descriptors,
        .dstBinding = binding,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image,
    };
    vkUpdateDescriptorSets(self->gpu->device, 1, &write, 0, NULL);
}

typedef struct { uint32_t width, height; } texture_size;

static bool ensure_texture(telar_vulkan_resources *self, gpu_texture *texture, texture_size size) {
    if (texture->width == size.width && texture->height == size.height) {
        return true;
    }
    destroy_texture(self, texture);
    VkDevice device = self->gpu->device;
    VkImageCreateInfo image = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = texture->format,
        .extent = {size.width, size.height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_TRY(vkCreateImage(device, &image, NULL, &texture->image));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(device, texture->image, &requirements);
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
    VK_TRY(vkAllocateMemory(device, &allocate, NULL, &texture->memory));
    VK_TRY(vkBindImageMemory(device, texture->image, texture->memory, 0));
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = texture->image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = texture->format,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VK_TRY(vkCreateImageView(device, &view, NULL, &texture->view));
    VkDeviceSize bytes = (VkDeviceSize)size.width * size.height * texture->bytes_per_texel;
    if (!ensure_buffer(self->gpu, &texture->staging, (buffer_request){bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT})) {
        return false;
    }
    texture->width = size.width;
    texture->height = size.height;
    return true;
}

typedef struct {
    const uint8_t *pixels;
    uint64_t version;
} texture_source;

static void upload_texture(telar_vulkan_resources *self, VkCommandBuffer commands, gpu_texture *texture,
                           texture_source source) {
    if (texture->uploaded && texture->version == source.version) {
        return;
    }
    memcpy(texture->staging.mapped, source.pixels, (size_t)texture->width * texture->height * texture->bytes_per_texel);
    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = texture->uploaded ? VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_2_NONE,
        .srcAccessMask = texture->uploaded ? VK_ACCESS_2_SHADER_SAMPLED_READ_BIT : 0,
        .dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .oldLayout = texture->uploaded ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = texture->image,
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
        .imageExtent = {texture->width, texture->height, 1},
    };
    vkCmdCopyBufferToImage(commands, texture->staging.handle, texture->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
                           &region);
    barrier.srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT;
    barrier.srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT;
    barrier.dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT;
    barrier.dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier2(commands, &dependency);
    texture->version = source.version;
    texture->uploaded = true;
}

telar_vulkan_resources *telar_vulkan_resources_create(const telar_vulkan_device *gpu, telar_vulkan_pipeline *pipeline) {
    telar_vulkan_resources *self = calloc(1, sizeof *self);
    if (self) {
        self->gpu = gpu;
        self->pipeline = pipeline;
        self->atlas.format = VK_FORMAT_R8_UNORM;
        self->atlas.bytes_per_texel = 1;
        self->atlas.binding = 1;
        self->sprites.format = VK_FORMAT_R8G8B8A8_UNORM;
        self->sprites.bytes_per_texel = 4;
        self->sprites.binding = 2;
        for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
            self->diagrams[i].format = VK_FORMAT_R8G8B8A8_UNORM;
            self->diagrams[i].bytes_per_texel = 4;
            self->diagrams[i].binding = 3 + i;
        }
    }
    return self;
}

bool telar_vulkan_resources_prepare(telar_vulkan_resources *self, VkCommandBuffer commands,
                                    const telar_gui_frame *frame) {
    if (!telar_gui_diagrams_valid(frame, self->gpu->limits.maxImageDimension2D)) {
        return false;
    }
    // The consumer waits for its previous fence before entering prepare.
    // Drop obsolete slots before admitting any new allocation into the quota.
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        const telar_gui_diagram_texture *source = &frame->diagrams[i];
        gpu_texture *image = &self->diagrams[i];
        if (!source->pixels || image->width != source->width || image->height != source->height) {
            destroy_texture(self, image);
        }
    }
    if (frame->quad_count == 0) {
        return true;
    }
    VkDeviceSize bytes = (VkDeviceSize)frame->quad_count * sizeof(telar_gui_quad);
    if (!frame->quads || !frame->atlas || !frame->atlas_side ||
        frame->atlas_side > self->gpu->limits.maxImageDimension2D || bytes > self->gpu->limits.maxStorageBufferRange) {
        return false;
    }
    bool sprites = frame->sprites && frame->sprites_side;
    if (sprites && frame->sprites_side > self->gpu->limits.maxImageDimension2D) {
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
    uint32_t atlas_side = self->atlas.width;
    if (!ensure_texture(self, &self->atlas, (texture_size){frame->atlas_side, frame->atlas_side})) {
        return false;
    }
    bool rebind_atlas = atlas_side != self->atlas.width;
    if (rebind_atlas) {
        bind_texture(self, self->atlas.binding, self->atlas.view, self->pipeline->sampler);
    }
    if (sprites) {
        uint32_t sprites_side = self->sprites.width;
        if (!ensure_texture(self, &self->sprites, (texture_size){frame->sprites_side, frame->sprites_side})) {
            return false;
        }
        if (sprites_side != self->sprites.width || !self->sprites_bound) {
            bind_texture(self, self->sprites.binding, self->sprites.view, self->pipeline->sprite_sampler);
            self->sprites_bound = true;
        }
    } else if (!self->sprites_bound || rebind_atlas) {
        // Every declared binding is written before the draw; the atlas stands
        // in for the sprite page until one arrives and no quad selects it.
        bind_texture(self, self->sprites.binding, self->atlas.view, self->pipeline->sprite_sampler);
    }
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        const telar_gui_diagram_texture *source = &frame->diagrams[i];
        gpu_texture *image = &self->diagrams[i];
        if (!source->pixels) {
            bind_texture(self, image->binding, self->atlas.view, self->pipeline->sprite_sampler);
            continue;
        }
        bool created = image->width == 0;
        if (!ensure_texture(self, image, (texture_size){source->width, source->height})) {
            return false;
        }
        if (created) {
            bind_texture(self, image->binding, image->view, self->pipeline->sprite_sampler);
        }
    }
    // Finish all fallible allocation before recording uploads and committing
    // their versions. An allocation failure must leave a retry uploadable.
    upload_texture(self, commands, &self->atlas, (texture_source){frame->atlas, frame->atlas_version});
    if (sprites) {
        upload_texture(self, commands, &self->sprites, (texture_source){frame->sprites, frame->sprites_version});
    }
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        const telar_gui_diagram_texture *source = &frame->diagrams[i];
        if (source->pixels) {
            upload_texture(self, commands, &self->diagrams[i], (texture_source){source->pixels, source->version});
        }
    }
    return true;
}

void telar_vulkan_resources_destroy(telar_vulkan_resources *self) {
    if (!self) {
        return;
    }
    destroy_texture(self, &self->atlas);
    destroy_texture(self, &self->sprites);
    for (unsigned i = 0; i < TELAR_GUI_DIAGRAM_SLOTS; i++) {
        destroy_texture(self, &self->diagrams[i]);
    }
    destroy_buffer(self->gpu->device, &self->quads);
    free(self);
}
