// Kitty graphics images by handle, uploaded on their own thread. The window
// thread accepts uploads and releases and takes completions; the frame
// worker only reads the descriptor set of a ready handle.
#pragma once
#include "../native/telar_gui.h"
#include "vulkan_device.h"

typedef struct telar_vulkan_images telar_vulkan_images;
typedef void (*telar_image_ready_fn)(void *context, uint32_t handle, int success);

telar_vulkan_images *telar_vulkan_images_create(const telar_vulkan_device *gpu);
// The set layout pipelines bind at set 1: one sampled image.
VkDescriptorSetLayout telar_vulkan_images_layout(const telar_vulkan_images *self);
// Window thread, no frame in flight: releases first, then queued uploads.
void telar_vulkan_images_accept(telar_vulkan_images *self, const telar_gui_frame *frame);
// Readable when uploads finished; take reports each one exactly once.
int telar_vulkan_images_fd(const telar_vulkan_images *self);
void telar_vulkan_images_take(telar_vulkan_images *self, telar_image_ready_fn ready, void *context);
// Frame worker: the set of a ready handle, or VK_NULL_HANDLE.
VkDescriptorSet telar_vulkan_images_set(telar_vulkan_images *self, uint32_t handle);
// A set every draw may bind when no image is selected.
VkDescriptorSet telar_vulkan_images_fallback(const telar_vulkan_images *self);
// Joins the upload thread, then frees every image.
void telar_vulkan_images_destroy(telar_vulkan_images *self);
