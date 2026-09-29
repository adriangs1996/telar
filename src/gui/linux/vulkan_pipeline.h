#pragma once
#include "vulkan_device.h"

typedef struct {
    VkDevice device;
    VkDescriptorSetLayout set_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptors;
    VkPipelineLayout layout;
    VkPipeline pipeline;
    // Nearest for the alpha atlas, linear for the premultiplied sprite page.
    VkSampler sampler;
    VkSampler sprite_sampler;
    VkFormat format;
} telar_vulkan_pipeline;

// `images` is the set 1 layout image quads bind (`vulkan_images.h`).
bool telar_vulkan_pipeline_init(telar_vulkan_pipeline *self, VkDevice device, VkFormat format,
                                VkDescriptorSetLayout images);
void telar_vulkan_pipeline_deinit(telar_vulkan_pipeline *self);
