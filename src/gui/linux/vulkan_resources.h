#pragma once
#include "../native/telar_gui.h"
#include "vulkan_pipeline.h"

typedef struct telar_vulkan_resources telar_vulkan_resources;
telar_vulkan_resources *telar_vulkan_resources_create(const telar_vulkan_device *gpu, telar_vulkan_pipeline *pipeline);
// Copy the sealed scene and record changed atlas uploads, e.g. prepare(resources, commands, frame).
// The caller must have completed the previous submission before invoking this.
bool telar_vulkan_resources_prepare(telar_vulkan_resources *self, VkCommandBuffer commands,
                                    const telar_gui_frame *frame);
void telar_vulkan_resources_destroy(telar_vulkan_resources *self);
