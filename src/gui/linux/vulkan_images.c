#include "vulkan_images.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Uploads copy through this much host-visible staging, a band of rows at a
// time, expanding RGB to RGBA on the way; nothing grows with the image.
#define STAGING_BYTES (4u * 1024u * 1024u)
#define RGB_BYTES 3u
#define RGBA_BYTES 4u
// Queued uploads and unreported completions; the client keeps at most
// TELAR_GUI_IMAGE_UPLOADS in flight, so these never fill in practice.
#define RING 16u

enum residency { FREE, UPLOADING, READY };

typedef struct {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkDescriptorSet set;
    enum residency residency;
} image_slot;

typedef struct {
    uint32_t handle;
    int success;
} completion;

struct telar_vulkan_images {
    const telar_vulkan_device *gpu;
    VkDescriptorSetLayout layout;
    VkDescriptorPool pool;
    VkSampler sampler;
    image_slot slots[TELAR_GUI_IMAGE_CAPACITY];
    // A 1x1 transparent image bound when a draw selects no image.
    image_slot fallback;
    VkBuffer staging;
    VkDeviceMemory staging_memory;
    uint8_t *staging_mapped;
    VkCommandPool commands_pool;
    VkCommandBuffer commands;
    VkFence fence;
    pthread_t thread;
    bool thread_started;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool stopping;
    telar_gui_image_upload queue[RING];
    uint32_t queue_head, queue_len;
    completion done[RING];
    uint32_t done_len;
    int wake[2];
};

static void destroy_slot(telar_vulkan_images *self, image_slot *slot) {
    VkDevice device = self->gpu->device;
    if (slot->view) {
        vkDestroyImageView(device, slot->view, NULL);
    }
    if (slot->image) {
        vkDestroyImage(device, slot->image, NULL);
    }
    if (slot->memory) {
        vkFreeMemory(device, slot->memory, NULL);
    }
    slot->view = VK_NULL_HANDLE;
    slot->image = VK_NULL_HANDLE;
    slot->memory = VK_NULL_HANDLE;
    slot->residency = FREE;
}

static bool create_image(telar_vulkan_images *self, image_slot *slot, uint32_t width, uint32_t height) {
    VkDevice device = self->gpu->device;
    VkImageCreateInfo image = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {width, height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_TRY(vkCreateImage(device, &image, NULL, &slot->image));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(device, slot->image, &requirements);
    uint32_t type = telar_vulkan_memory_type(self->gpu, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
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
    VK_TRY(vkAllocateMemory(device, &allocate, NULL, &slot->memory));
    VK_TRY(vkBindImageMemory(device, slot->image, slot->memory, 0));
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = slot->image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VK_TRY(vkCreateImageView(device, &view, NULL, &slot->view));
    VkDescriptorImageInfo sampled = {self->sampler, slot->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = slot->set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &sampled,
    };
    vkUpdateDescriptorSets(device, 1, &write, 0, NULL);
    return true;
}

static void layout_barrier(VkCommandBuffer commands, VkImage image, bool first) {
    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = first ? VK_PIPELINE_STAGE_2_NONE : VK_PIPELINE_STAGE_2_COPY_BIT,
        .srcAccessMask = first ? 0 : VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .dstStageMask = first ? VK_PIPELINE_STAGE_2_COPY_BIT : VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
        .dstAccessMask = first ? VK_ACCESS_2_TRANSFER_WRITE_BIT : VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        .oldLayout = first ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = first ? VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
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
    vkCmdPipelineBarrier2(commands, &dependency);
}

typedef struct {
    uint32_t top, rows;
    bool first, last;
} band;

// Records and submits one band, then waits for it: the staging buffer is
// reused by the next band. The queue lock is the frame worker's too.
static bool submit_band(telar_vulkan_images *self, VkImage image, uint32_t width, band part) {
    VK_TRY(vkResetCommandBuffer(self->commands, 0));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    VK_TRY(vkBeginCommandBuffer(self->commands, &begin));
    if (part.first) {
        layout_barrier(self->commands, image, true);
    }
    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageOffset = {0, (int32_t)part.top, 0},
        .imageExtent = {width, part.rows, 1},
    };
    vkCmdCopyBufferToImage(self->commands, self->staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    if (part.last) {
        layout_barrier(self->commands, image, false);
    }
    VK_TRY(vkEndCommandBuffer(self->commands));
    VkCommandBufferSubmitInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = self->commands,
    };
    VkSubmitInfo2 info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &commands,
    };
    VK_TRY(vkResetFences(self->gpu->device, 1, &self->fence));
    pthread_mutex_lock((pthread_mutex_t *)&self->gpu->queue_lock);
    VkResult submitted = vkQueueSubmit2(self->gpu->queue, 1, &info, self->fence);
    pthread_mutex_unlock((pthread_mutex_t *)&self->gpu->queue_lock);
    VK_TRY(submitted);
    VK_TRY(vkWaitForFences(self->gpu->device, 1, &self->fence, VK_TRUE, UINT64_MAX));
    return true;
}

static bool upload(telar_vulkan_images *self, image_slot *slot, telar_gui_image_upload request) {
    if (request.width > self->gpu->limits.maxImageDimension2D || request.height > self->gpu->limits.maxImageDimension2D ||
        !create_image(self, slot, request.width, request.height)) {
        return false;
    }
    size_t row_bytes = (size_t)request.width * RGBA_BYTES;
    uint32_t rows_per_band = (uint32_t)(STAGING_BYTES / row_bytes);
    const uint8_t *source = request.pixels;
    for (uint32_t top = 0; top < request.height; top += rows_per_band) {
        uint32_t rows = request.height - top < rows_per_band ? request.height - top : rows_per_band;
        size_t pixels = (size_t)rows * request.width;
        if (request.bytes_per_pixel == RGBA_BYTES) {
            memcpy(self->staging_mapped, source, pixels * RGBA_BYTES);
            source += pixels * RGBA_BYTES;
        } else {
            for (size_t i = 0; i < pixels; i++) {
                self->staging_mapped[i * RGBA_BYTES + 0] = source[0];
                self->staging_mapped[i * RGBA_BYTES + 1] = source[1];
                self->staging_mapped[i * RGBA_BYTES + 2] = source[2];
                self->staging_mapped[i * RGBA_BYTES + 3] = UINT8_MAX;
                source += RGB_BYTES;
            }
        }
        band part = {top, rows, top == 0, top + rows == request.height};
        if (!submit_band(self, slot->image, request.width, part)) {
            return false;
        }
    }
    return true;
}

static void *run(void *context) {
    telar_vulkan_images *self = context;
    pthread_mutex_lock(&self->mutex);
    for (;;) {
        while (self->queue_len == 0 && !self->stopping) {
            pthread_cond_wait(&self->condition, &self->mutex);
        }
        if (self->stopping) {
            break;
        }
        telar_gui_image_upload request = self->queue[self->queue_head];
        self->queue_head = (self->queue_head + 1) % RING;
        self->queue_len--;
        image_slot *slot = &self->slots[request.handle - 1];
        pthread_mutex_unlock(&self->mutex);
        bool ok = upload(self, slot, request);
        pthread_mutex_lock(&self->mutex);
        if (ok) {
            slot->residency = READY;
        } else {
            destroy_slot(self, slot);
        }
        self->done[self->done_len++] = (completion){request.handle, ok ? 1 : 0};
        telar_gui_wake(self->wake[1]);
    }
    pthread_mutex_unlock(&self->mutex);
    return NULL;
}

static bool create_staging(telar_vulkan_images *self) {
    VkDevice device = self->gpu->device;
    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = STAGING_BYTES,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VK_TRY(vkCreateBuffer(device, &info, NULL, &self->staging));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, self->staging, &requirements);
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = telar_vulkan_memory_type(self->gpu, requirements.memoryTypeBits,
                                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    if (allocate.memoryTypeIndex == UINT32_MAX) {
        return false;
    }
    VK_TRY(vkAllocateMemory(device, &allocate, NULL, &self->staging_memory));
    VK_TRY(vkBindBufferMemory(device, self->staging, self->staging_memory, 0));
    void *mapped = NULL;
    VK_TRY(vkMapMemory(device, self->staging_memory, 0, STAGING_BYTES, 0, &mapped));
    self->staging_mapped = mapped;
    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self->gpu->queue_family,
    };
    VK_TRY(vkCreateCommandPool(device, &pool, NULL, &self->commands_pool));
    VkCommandBufferAllocateInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self->commands_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VK_TRY(vkAllocateCommandBuffers(device, &commands, &self->commands));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VK_TRY(vkCreateFence(device, &fence, NULL, &self->fence));
    return true;
}

static bool create_descriptors(telar_vulkan_images *self) {
    VkDevice device = self->gpu->device;
    VkDescriptorSetLayoutBinding binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    VkDescriptorSetLayoutCreateInfo layout = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    VK_TRY(vkCreateDescriptorSetLayout(device, &layout, NULL, &self->layout));
    VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, TELAR_GUI_IMAGE_CAPACITY + 1};
    VkDescriptorPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = TELAR_GUI_IMAGE_CAPACITY + 1,
        .poolSizeCount = 1,
        .pPoolSizes = &size,
    };
    VK_TRY(vkCreateDescriptorPool(device, &pool, NULL, &self->pool));
    VkDescriptorSetAllocateInfo set = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self->pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self->layout,
    };
    for (unsigned i = 0; i < TELAR_GUI_IMAGE_CAPACITY; i++) {
        VK_TRY(vkAllocateDescriptorSets(device, &set, &self->slots[i].set));
    }
    VK_TRY(vkAllocateDescriptorSets(device, &set, &self->fallback.set));
    VkSamplerCreateInfo sampler = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_LINEAR,
        .minFilter = VK_FILTER_LINEAR,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    VK_TRY(vkCreateSampler(device, &sampler, NULL, &self->sampler));
    static const uint8_t transparent[RGBA_BYTES] = {0};
    telar_gui_image_upload blank = {transparent, 0, 1, 1, RGBA_BYTES};
    return upload(self, &self->fallback, blank);
}

telar_vulkan_images *telar_vulkan_images_create(const telar_vulkan_device *gpu) {
    telar_vulkan_images *self = calloc(1, sizeof *self);
    if (!self) {
        return NULL;
    }
    self->gpu = gpu;
    self->wake[0] = self->wake[1] = -1;
    if (pthread_mutex_init(&self->mutex, NULL) != 0 || pthread_cond_init(&self->condition, NULL) != 0 ||
        telar_gui_pipe(self->wake) != 0 || !create_staging(self) || !create_descriptors(self) ||
        pthread_create(&self->thread, NULL, run, self) != 0) {
        telar_vulkan_images_destroy(self);
        return NULL;
    }
    self->thread_started = true;
    return self;
}

VkDescriptorSetLayout telar_vulkan_images_layout(const telar_vulkan_images *self) { return self->layout; }

static bool upload_valid(telar_gui_image_upload upload) {
    return upload.pixels != NULL && upload.handle >= 1 && upload.handle <= TELAR_GUI_IMAGE_CAPACITY &&
           upload.width >= 1 && upload.height >= 1 && upload.width <= TELAR_GUI_IMAGE_MAX_SIDE &&
           upload.height <= TELAR_GUI_IMAGE_MAX_SIDE &&
           (upload.bytes_per_pixel == RGB_BYTES || upload.bytes_per_pixel == RGBA_BYTES);
}

void telar_vulkan_images_accept(telar_vulkan_images *self, const telar_gui_frame *frame) {
    pthread_mutex_lock(&self->mutex);
    if (frame->image_releases != NULL) {
        for (uint32_t i = 0; i < frame->image_release_count; i++) {
            uint32_t handle = frame->image_releases[i];
            if (handle >= 1 && handle <= TELAR_GUI_IMAGE_CAPACITY && self->slots[handle - 1].residency == READY) {
                destroy_slot(self, &self->slots[handle - 1]);
            }
        }
    }
    uint32_t count = frame->image_uploads != NULL ? frame->image_upload_count : 0;
    if (count > TELAR_GUI_IMAGE_UPLOADS) {
        count = TELAR_GUI_IMAGE_UPLOADS;
    }
    for (uint32_t i = 0; i < count; i++) {
        telar_gui_image_upload upload = frame->image_uploads[i];
        bool taken = upload.handle >= 1 && upload.handle <= TELAR_GUI_IMAGE_CAPACITY &&
                     self->slots[upload.handle - 1].residency != FREE;
        if (!upload_valid(upload) || taken || self->queue_len == RING || self->done_len + self->queue_len >= RING) {
            if (!taken && upload.handle >= 1 && upload.handle <= TELAR_GUI_IMAGE_CAPACITY && self->done_len < RING) {
                self->done[self->done_len++] = (completion){upload.handle, 0};
                telar_gui_wake(self->wake[1]);
            }
            continue;
        }
        self->slots[upload.handle - 1].residency = UPLOADING;
        self->queue[(self->queue_head + self->queue_len) % RING] = upload;
        self->queue_len++;
    }
    pthread_cond_signal(&self->condition);
    pthread_mutex_unlock(&self->mutex);
}

int telar_vulkan_images_fd(const telar_vulkan_images *self) { return self->wake[0]; }

void telar_vulkan_images_take(telar_vulkan_images *self, telar_image_ready_fn ready, void *context) {
    telar_gui_drain(self->wake[0]);
    completion taken[RING];
    pthread_mutex_lock(&self->mutex);
    uint32_t count = self->done_len;
    memcpy(taken, self->done, count * sizeof *taken);
    self->done_len = 0;
    pthread_mutex_unlock(&self->mutex);
    for (uint32_t i = 0; i < count; i++) {
        if (ready != NULL) {
            ready(context, taken[i].handle, taken[i].success);
        }
    }
}

VkDescriptorSet telar_vulkan_images_set(telar_vulkan_images *self, uint32_t handle) {
    if (handle < 1 || handle > TELAR_GUI_IMAGE_CAPACITY) {
        return VK_NULL_HANDLE;
    }
    pthread_mutex_lock(&self->mutex);
    VkDescriptorSet set = self->slots[handle - 1].residency == READY ? self->slots[handle - 1].set : VK_NULL_HANDLE;
    pthread_mutex_unlock(&self->mutex);
    return set;
}

VkDescriptorSet telar_vulkan_images_fallback(const telar_vulkan_images *self) { return self->fallback.set; }

void telar_vulkan_images_destroy(telar_vulkan_images *self) {
    if (!self) {
        return;
    }
    if (self->thread_started) {
        pthread_mutex_lock(&self->mutex);
        self->stopping = true;
        pthread_cond_signal(&self->condition);
        pthread_mutex_unlock(&self->mutex);
        pthread_join(self->thread, NULL);
    }
    VkDevice device = self->gpu->device;
    if (device) {
        vkDeviceWaitIdle(device);
        for (unsigned i = 0; i < TELAR_GUI_IMAGE_CAPACITY; i++) {
            destroy_slot(self, &self->slots[i]);
        }
        destroy_slot(self, &self->fallback);
        if (self->sampler) {
            vkDestroySampler(device, self->sampler, NULL);
        }
        if (self->pool) {
            vkDestroyDescriptorPool(device, self->pool, NULL);
        }
        if (self->layout) {
            vkDestroyDescriptorSetLayout(device, self->layout, NULL);
        }
        if (self->fence) {
            vkDestroyFence(device, self->fence, NULL);
        }
        if (self->commands_pool) {
            vkDestroyCommandPool(device, self->commands_pool, NULL);
        }
        if (self->staging_mapped) {
            vkUnmapMemory(device, self->staging_memory);
        }
        if (self->staging) {
            vkDestroyBuffer(device, self->staging, NULL);
        }
        if (self->staging_memory) {
            vkFreeMemory(device, self->staging_memory, NULL);
        }
    }
    if (self->wake[0] >= 0) {
        telar_gui_close_pipe(self->wake);
    }
    pthread_cond_destroy(&self->condition);
    pthread_mutex_destroy(&self->mutex);
    free(self);
}
