// Vulkan consumer of the quad buffer. One queue, one command buffer and one
// frame in flight: the window paints on configure, not on a clock, so the
// simplest correct pipeline wins until pacing exists.
#define VK_USE_PLATFORM_WAYLAND_KHR
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#include "renderer.h"

extern const uint32_t telar_gui_quad_vert_spv[];
extern const uint32_t telar_gui_quad_vert_spv_bytes;
extern const uint32_t telar_gui_quad_frag_spv[];
extern const uint32_t telar_gui_quad_frag_spv_bytes;

struct telar_renderer {
    VkInstance instance;
    VkSurfaceKHR surface;
    VkPhysicalDevice physical;
    uint32_t queue_family;
    VkDevice device;
    VkQueue queue;
    VkCommandPool pool;
    VkCommandBuffer commands;
    VkFence fence;
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkDescriptorSetLayout set_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptors;
    VkPipelineLayout layout;
    VkRenderPass pass;
    VkPipeline pipeline;
    VkSampler sampler;
    VkSwapchainKHR swapchain;
    VkFormat format;
    VkExtent2D extent;
    uint32_t image_count;
    VkImage images[8];
    VkImageView views[8];
    VkFramebuffer framebuffers[8];
    VkBuffer quads;
    VkDeviceMemory quads_memory;
    VkDeviceSize quads_capacity;
    VkBuffer staging;
    VkDeviceMemory staging_memory;
    VkDeviceSize staging_capacity;
    VkImage atlas;
    VkDeviceMemory atlas_memory;
    VkImageView atlas_view;
    uint32_t atlas_side;
    uint32_t atlas_version;
    bool atlas_bound;
};

#define TRY(step) \
    do { \
        VkResult result_ = (step); \
        if (result_ != VK_SUCCESS) { \
            fprintf(stderr, "telar gui: %s failed: %d\n", #step, (int)result_); \
            return false; \
        } \
    } while (0)

static uint32_t find_memory(telar_renderer *self, uint32_t type_bits, VkMemoryPropertyFlags wanted) {
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(self->physical, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((type_bits & (1u << i)) && (properties.memoryTypes[i].propertyFlags & wanted) == wanted) return i;
    }
    return UINT32_MAX;
}

static bool create_buffer(telar_renderer *self, VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer *buffer, VkDeviceMemory *memory) {
    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    TRY(vkCreateBuffer(self->device, &info, NULL, buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(self->device, *buffer, &requirements);
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = find_memory(self, requirements.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    if (allocate.memoryTypeIndex == UINT32_MAX) {
        fprintf(stderr, "telar gui: no host-visible memory\n");
        return false;
    }
    TRY(vkAllocateMemory(self->device, &allocate, NULL, memory));
    TRY(vkBindBufferMemory(self->device, *buffer, *memory, 0));
    return true;
}

static bool create_instance(telar_renderer *self, struct wl_display *display, struct wl_surface *surface) {
    const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME};
    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "telar",
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = extensions,
    };
    TRY(vkCreateInstance(&info, NULL, &self->instance));
    VkWaylandSurfaceCreateInfoKHR surface_info = {
        .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = display,
        .surface = surface,
    };
    TRY(vkCreateWaylandSurfaceKHR(self->instance, &surface_info, NULL, &self->surface));
    return true;
}

static bool pick_device(telar_renderer *self) {
    uint32_t count = 0;
    TRY(vkEnumeratePhysicalDevices(self->instance, &count, NULL));
    if (count == 0) {
        fprintf(stderr, "telar gui: no Vulkan device\n");
        return false;
    }
    if (count > 16) count = 16;
    VkPhysicalDevice devices[16];
    TRY(vkEnumeratePhysicalDevices(self->instance, &count, devices));
    for (uint32_t d = 0; d < count; d++) {
        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, NULL);
        if (families > 16) families = 16;
        VkQueueFamilyProperties properties[16];
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, properties);
        for (uint32_t f = 0; f < families; f++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(devices[d], f, self->surface, &present);
            if ((properties[f].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                self->physical = devices[d];
                self->queue_family = f;
                return true;
            }
        }
    }
    fprintf(stderr, "telar gui: no queue draws and presents on this surface\n");
    return false;
}

static bool create_device(telar_renderer *self) {
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = self->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = extensions,
    };
    TRY(vkCreateDevice(self->physical, &info, NULL, &self->device));
    vkGetDeviceQueue(self->device, self->queue_family, 0, &self->queue);

    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self->queue_family,
    };
    TRY(vkCreateCommandPool(self->device, &pool, NULL, &self->pool));
    VkCommandBufferAllocateInfo commands = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self->pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    TRY(vkAllocateCommandBuffers(self->device, &commands, &self->commands));
    VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
    TRY(vkCreateFence(self->device, &fence, NULL, &self->fence));
    VkSemaphoreCreateInfo semaphore = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    TRY(vkCreateSemaphore(self->device, &semaphore, NULL, &self->image_available));
    TRY(vkCreateSemaphore(self->device, &semaphore, NULL, &self->render_finished));
    return true;
}

static void destroy_swapchain(telar_renderer *self) {
    for (uint32_t i = 0; i < self->image_count; i++) {
        if (self->framebuffers[i] != VK_NULL_HANDLE) vkDestroyFramebuffer(self->device, self->framebuffers[i], NULL);
        if (self->views[i] != VK_NULL_HANDLE) vkDestroyImageView(self->device, self->views[i], NULL);
        self->framebuffers[i] = VK_NULL_HANDLE;
        self->views[i] = VK_NULL_HANDLE;
    }
    self->image_count = 0;
    if (self->swapchain != VK_NULL_HANDLE) vkDestroySwapchainKHR(self->device, self->swapchain, NULL);
    self->swapchain = VK_NULL_HANDLE;
}

static bool create_swapchain(telar_renderer *self, telar_gui_viewport viewport) {
    VkSurfaceCapabilitiesKHR capabilities;
    TRY(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self->physical, self->surface, &capabilities));
    uint32_t format_count = 0;
    TRY(vkGetPhysicalDeviceSurfaceFormatsKHR(self->physical, self->surface, &format_count, NULL));
    if (format_count > 32) format_count = 32;
    VkSurfaceFormatKHR formats[32];
    TRY(vkGetPhysicalDeviceSurfaceFormatsKHR(self->physical, self->surface, &format_count, formats));
    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i = 0; i < format_count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) chosen = formats[i];
    }

    VkExtent2D extent = capabilities.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = viewport.width;
        extent.height = viewport.height;
    }
    uint32_t wanted = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 && wanted > capabilities.maxImageCount) wanted = capabilities.maxImageCount;
    if (wanted > 8) wanted = 8;

    VkSwapchainKHR previous = self->swapchain;
    VkSwapchainCreateInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = self->surface,
        .minImageCount = wanted,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
        .oldSwapchain = previous,
    };
    VkSwapchainKHR swapchain;
    TRY(vkCreateSwapchainKHR(self->device, &info, NULL, &swapchain));
    destroy_swapchain(self);
    self->swapchain = swapchain;
    self->format = chosen.format;
    self->extent = extent;

    uint32_t count = 0;
    TRY(vkGetSwapchainImagesKHR(self->device, self->swapchain, &count, NULL));
    if (count > 8) {
        fprintf(stderr, "telar gui: swapchain returned %u images\n", count);
        return false;
    }
    TRY(vkGetSwapchainImagesKHR(self->device, self->swapchain, &count, self->images));
    self->image_count = count;
    for (uint32_t i = 0; i < count; i++) {
        VkImageViewCreateInfo view = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = self->format,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        TRY(vkCreateImageView(self->device, &view, NULL, &self->views[i]));
        VkFramebufferCreateInfo framebuffer = {
            .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = self->pass,
            .attachmentCount = 1,
            .pAttachments = &self->views[i],
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        TRY(vkCreateFramebuffer(self->device, &framebuffer, NULL, &self->framebuffers[i]));
    }
    return true;
}

static bool create_pass(telar_renderer *self, VkFormat format) {
    VkAttachmentDescription color = {
        .format = format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    VkAttachmentReference reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &reference,
    };
    VkSubpassDependency dependency = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    VkRenderPassCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };
    TRY(vkCreateRenderPass(self->device, &info, NULL, &self->pass));
    return true;
}

static bool create_shader(telar_renderer *self, const uint32_t *code, uint32_t bytes, VkShaderModule *module) {
    VkShaderModuleCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = bytes,
        .pCode = code,
    };
    TRY(vkCreateShaderModule(self->device, &info, NULL, module));
    return true;
}

static bool create_pipeline(telar_renderer *self) {
    VkDescriptorSetLayoutBinding bindings[2] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_VERTEX_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
    };
    VkDescriptorSetLayoutCreateInfo set_layout = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 2,
        .pBindings = bindings,
    };
    TRY(vkCreateDescriptorSetLayout(self->device, &set_layout, NULL, &self->set_layout));
    VkDescriptorPoolSize sizes[2] = {
        {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1},
        {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1},
    };
    VkDescriptorPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1,
        .poolSizeCount = 2,
        .pPoolSizes = sizes,
    };
    TRY(vkCreateDescriptorPool(self->device, &pool, NULL, &self->descriptor_pool));
    VkDescriptorSetAllocateInfo set = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self->descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self->set_layout,
    };
    TRY(vkAllocateDescriptorSets(self->device, &set, &self->descriptors));

    VkPushConstantRange push = {.stageFlags = VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 2 * sizeof(float)};
    VkPipelineLayoutCreateInfo layout = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self->set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push,
    };
    TRY(vkCreatePipelineLayout(self->device, &layout, NULL, &self->layout));

    VkShaderModule vert, frag;
    if (!create_shader(self, telar_gui_quad_vert_spv, telar_gui_quad_vert_spv_bytes, &vert)) return false;
    if (!create_shader(self, telar_gui_quad_frag_spv, telar_gui_quad_frag_spv_bytes, &frag)) {
        vkDestroyShaderModule(self->device, vert, NULL);
        return false;
    }
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vert, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main"},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    VkPipelineViewportStateCreateInfo viewport = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    VkPipelineRasterizationStateCreateInfo raster = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_CLOCKWISE,
        .lineWidth = 1.0f,
    };
    VkPipelineMultisampleStateCreateInfo multisample = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    VkPipelineColorBlendAttachmentState blend_attachment = {
        .blendEnable = VK_TRUE,
        .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = VK_BLEND_OP_ADD,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    };
    VkPipelineColorBlendStateCreateInfo blend = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };
    VkDynamicState dynamic_states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dynamic_states,
    };
    VkGraphicsPipelineCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &assembly,
        .pViewportState = &viewport,
        .pRasterizationState = &raster,
        .pMultisampleState = &multisample,
        .pColorBlendState = &blend,
        .pDynamicState = &dynamic,
        .layout = self->layout,
        .renderPass = self->pass,
        .subpass = 0,
    };
    VkResult created = vkCreateGraphicsPipelines(self->device, VK_NULL_HANDLE, 1, &info, NULL, &self->pipeline);
    vkDestroyShaderModule(self->device, vert, NULL);
    vkDestroyShaderModule(self->device, frag, NULL);
    if (created != VK_SUCCESS) {
        fprintf(stderr, "telar gui: pipeline creation failed: %d\n", (int)created);
        return false;
    }

    VkSamplerCreateInfo sampler = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_NEAREST,
        .minFilter = VK_FILTER_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    TRY(vkCreateSampler(self->device, &sampler, NULL, &self->sampler));
    return true;
}

static bool ensure_quads(telar_renderer *self, VkDeviceSize bytes) {
    if (self->quads != VK_NULL_HANDLE && self->quads_capacity >= bytes) return true;
    if (self->quads != VK_NULL_HANDLE) {
        vkDestroyBuffer(self->device, self->quads, NULL);
        vkFreeMemory(self->device, self->quads_memory, NULL);
    }
    VkDeviceSize capacity = 4096;
    while (capacity < bytes) capacity *= 2;
    if (!create_buffer(self, capacity, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, &self->quads, &self->quads_memory)) return false;
    self->quads_capacity = capacity;
    VkDescriptorBufferInfo buffer = {self->quads, 0, VK_WHOLE_SIZE};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self->descriptors,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &buffer,
    };
    vkUpdateDescriptorSets(self->device, 1, &write, 0, NULL);
    return true;
}

static bool ensure_atlas(telar_renderer *self, uint32_t side) {
    if (self->atlas != VK_NULL_HANDLE && self->atlas_side == side) return true;
    if (self->atlas != VK_NULL_HANDLE) {
        vkDestroyImageView(self->device, self->atlas_view, NULL);
        vkDestroyImage(self->device, self->atlas, NULL);
        vkFreeMemory(self->device, self->atlas_memory, NULL);
    }
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
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    TRY(vkCreateImage(self->device, &image, NULL, &self->atlas));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(self->device, self->atlas, &requirements);
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = find_memory(self, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    };
    if (allocate.memoryTypeIndex == UINT32_MAX) allocate.memoryTypeIndex = find_memory(self, requirements.memoryTypeBits, 0);
    TRY(vkAllocateMemory(self->device, &allocate, NULL, &self->atlas_memory));
    TRY(vkBindImageMemory(self->device, self->atlas, self->atlas_memory, 0));
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self->atlas,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    TRY(vkCreateImageView(self->device, &view, NULL, &self->atlas_view));
    self->atlas_side = side;
    self->atlas_version = 0;
    self->atlas_bound = false;

    VkDeviceSize bytes = (VkDeviceSize)side * side;
    if (self->staging == VK_NULL_HANDLE || self->staging_capacity < bytes) {
        if (self->staging != VK_NULL_HANDLE) {
            vkDestroyBuffer(self->device, self->staging, NULL);
            vkFreeMemory(self->device, self->staging_memory, NULL);
        }
        if (!create_buffer(self, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &self->staging, &self->staging_memory)) return false;
        self->staging_capacity = bytes;
    }

    VkDescriptorImageInfo info = {self->sampler, self->atlas_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self->descriptors,
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &info,
    };
    vkUpdateDescriptorSets(self->device, 1, &write, 0, NULL);
    return true;
}

// Records the staging copy for a changed page. The image goes through a
// transfer layout and comes out readable by the fragment shader.
static bool upload_atlas(telar_renderer *self, const telar_gui_frame *frame) {
    bool changed = frame->atlas_version != self->atlas_version;
    if (!changed && self->atlas_bound) return true;
    VkImageMemoryBarrier to_transfer = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = self->atlas,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(self->commands, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_transfer);

    void *mapped;
    VkDeviceSize bytes = (VkDeviceSize)frame->atlas_side * frame->atlas_side;
    TRY(vkMapMemory(self->device, self->staging_memory, 0, bytes, 0, &mapped));
    memcpy(mapped, frame->atlas, bytes);
    vkUnmapMemory(self->device, self->staging_memory);
    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {frame->atlas_side, frame->atlas_side, 1},
    };
    vkCmdCopyBufferToImage(self->commands, self->staging, self->atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    VkImageMemoryBarrier to_shader = to_transfer;
    to_shader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_shader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    to_shader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_shader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    vkCmdPipelineBarrier(self->commands, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &to_shader);
    self->atlas_version = frame->atlas_version;
    self->atlas_bound = true;
    return true;
}

telar_renderer *telar_renderer_create(struct wl_display *display, struct wl_surface *surface, telar_gui_viewport viewport) {
    telar_renderer *self = calloc(1, sizeof *self);
    if (self == NULL) return NULL;
    if (!create_instance(self, display, surface) || !pick_device(self) || !create_device(self)) {
        telar_renderer_destroy(self);
        return NULL;
    }
    // The render pass is created once, so it needs the surface format first.
    VkFormat format = VK_FORMAT_B8G8R8A8_UNORM;
    uint32_t all = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(self->physical, self->surface, &all, NULL);
    if (all > 32) all = 32;
    VkSurfaceFormatKHR formats[32];
    vkGetPhysicalDeviceSurfaceFormatsKHR(self->physical, self->surface, &all, formats);
    bool bgra = false;
    for (uint32_t i = 0; i < all; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) bgra = true;
    }
    if (!bgra && all > 0) format = formats[0].format;
    if (!create_pass(self, format) || !create_pipeline(self) || !create_swapchain(self, viewport)) {
        telar_renderer_destroy(self);
        return NULL;
    }
    return self;
}

bool telar_renderer_draw(telar_renderer *self, telar_gui_viewport viewport, const telar_gui_frame *frame) {
    TRY(vkWaitForFences(self->device, 1, &self->fence, VK_TRUE, UINT64_MAX));
    if (self->extent.width != viewport.width || self->extent.height != viewport.height) {
        TRY(vkDeviceWaitIdle(self->device));
        if (!create_swapchain(self, viewport)) return false;
    }

    uint32_t index;
    VkResult acquired = vkAcquireNextImageKHR(self->device, self->swapchain, UINT64_MAX, self->image_available, VK_NULL_HANDLE, &index);
    if (acquired == VK_ERROR_OUT_OF_DATE_KHR) {
        TRY(vkDeviceWaitIdle(self->device));
        if (!create_swapchain(self, viewport)) return false;
        TRY(vkAcquireNextImageKHR(self->device, self->swapchain, UINT64_MAX, self->image_available, VK_NULL_HANDLE, &index));
    } else if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR) {
        fprintf(stderr, "telar gui: acquire failed: %d\n", (int)acquired);
        return false;
    }
    TRY(vkResetFences(self->device, 1, &self->fence));

    bool has_quads = frame->quad_count > 0 && frame->quads != NULL && frame->atlas != NULL && frame->atlas_side > 0;
    if (has_quads) {
        if (!ensure_quads(self, (VkDeviceSize)frame->quad_count * sizeof(telar_gui_quad))) return false;
        if (!ensure_atlas(self, frame->atlas_side)) return false;
        void *mapped;
        TRY(vkMapMemory(self->device, self->quads_memory, 0, (VkDeviceSize)frame->quad_count * sizeof(telar_gui_quad), 0, &mapped));
        memcpy(mapped, frame->quads, (size_t)frame->quad_count * sizeof(telar_gui_quad));
        vkUnmapMemory(self->device, self->quads_memory);
    }

    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    TRY(vkBeginCommandBuffer(self->commands, &begin));
    if (has_quads && !upload_atlas(self, frame)) return false;

    VkClearValue clear = {.color = {{frame->background[0], frame->background[1], frame->background[2], frame->background[3]}}};
    VkRenderPassBeginInfo pass = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self->pass,
        .framebuffer = self->framebuffers[index],
        .renderArea = {{0, 0}, self->extent},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(self->commands, &pass, VK_SUBPASS_CONTENTS_INLINE);
    if (has_quads) {
        VkViewport vp = {0.0f, 0.0f, (float)self->extent.width, (float)self->extent.height, 0.0f, 1.0f};
        VkRect2D scissor = {{0, 0}, self->extent};
        float push[2] = {(float)self->extent.width, (float)self->extent.height};
        vkCmdBindPipeline(self->commands, VK_PIPELINE_BIND_POINT_GRAPHICS, self->pipeline);
        vkCmdSetViewport(self->commands, 0, 1, &vp);
        vkCmdSetScissor(self->commands, 0, 1, &scissor);
        vkCmdBindDescriptorSets(self->commands, VK_PIPELINE_BIND_POINT_GRAPHICS, self->layout, 0, 1, &self->descriptors, 0, NULL);
        vkCmdPushConstants(self->commands, self->layout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof push, push);
        vkCmdDraw(self->commands, 6, frame->quad_count, 0, 0);
    }
    vkCmdEndRenderPass(self->commands);
    TRY(vkEndCommandBuffer(self->commands));

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self->image_available,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &self->commands,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &self->render_finished,
    };
    TRY(vkQueueSubmit(self->queue, 1, &submit, self->fence));
    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self->render_finished,
        .swapchainCount = 1,
        .pSwapchains = &self->swapchain,
        .pImageIndices = &index,
    };
    VkResult presented = vkQueuePresentKHR(self->queue, &present);
    if (presented != VK_SUCCESS && presented != VK_SUBOPTIMAL_KHR && presented != VK_ERROR_OUT_OF_DATE_KHR) {
        fprintf(stderr, "telar gui: present failed: %d\n", (int)presented);
        return false;
    }
    return true;
}

void telar_renderer_destroy(telar_renderer *self) {
    if (self->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(self->device);
        destroy_swapchain(self);
        if (self->atlas_view != VK_NULL_HANDLE) vkDestroyImageView(self->device, self->atlas_view, NULL);
        if (self->atlas != VK_NULL_HANDLE) vkDestroyImage(self->device, self->atlas, NULL);
        if (self->atlas_memory != VK_NULL_HANDLE) vkFreeMemory(self->device, self->atlas_memory, NULL);
        if (self->staging != VK_NULL_HANDLE) vkDestroyBuffer(self->device, self->staging, NULL);
        if (self->staging_memory != VK_NULL_HANDLE) vkFreeMemory(self->device, self->staging_memory, NULL);
        if (self->quads != VK_NULL_HANDLE) vkDestroyBuffer(self->device, self->quads, NULL);
        if (self->quads_memory != VK_NULL_HANDLE) vkFreeMemory(self->device, self->quads_memory, NULL);
        if (self->sampler != VK_NULL_HANDLE) vkDestroySampler(self->device, self->sampler, NULL);
        if (self->pipeline != VK_NULL_HANDLE) vkDestroyPipeline(self->device, self->pipeline, NULL);
        if (self->pass != VK_NULL_HANDLE) vkDestroyRenderPass(self->device, self->pass, NULL);
        if (self->layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(self->device, self->layout, NULL);
        if (self->descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(self->device, self->descriptor_pool, NULL);
        if (self->set_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(self->device, self->set_layout, NULL);
        if (self->render_finished != VK_NULL_HANDLE) vkDestroySemaphore(self->device, self->render_finished, NULL);
        if (self->image_available != VK_NULL_HANDLE) vkDestroySemaphore(self->device, self->image_available, NULL);
        if (self->fence != VK_NULL_HANDLE) vkDestroyFence(self->device, self->fence, NULL);
        if (self->pool != VK_NULL_HANDLE) vkDestroyCommandPool(self->device, self->pool, NULL);
        vkDestroyDevice(self->device, NULL);
    }
    if (self->surface != VK_NULL_HANDLE) vkDestroySurfaceKHR(self->instance, self->surface, NULL);
    if (self->instance != VK_NULL_HANDLE) vkDestroyInstance(self->instance, NULL);
    free(self);
}
