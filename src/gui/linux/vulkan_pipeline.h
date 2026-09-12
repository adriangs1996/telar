#pragma once
#include "vulkan_device.h"

typedef struct {
    VkDevice device;
    VkDescriptorSetLayout set_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptors;
    VkPipelineLayout layout;
    VkPipeline pipeline;
    VkSampler sampler;
    VkFormat format;
} telar_vulkan_pipeline;

bool telar_vulkan_pipeline_init(telar_vulkan_pipeline *self, VkDevice device, VkFormat format);
void telar_vulkan_pipeline_deinit(telar_vulkan_pipeline *self);
