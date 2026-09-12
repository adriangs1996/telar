#include "vulkan_pipeline.h"
#include <string.h>

extern const uint32_t telar_gui_quad_vert_spv[];
extern const uint32_t telar_gui_quad_vert_spv_bytes;
extern const uint32_t telar_gui_quad_frag_spv[];
extern const uint32_t telar_gui_quad_frag_spv_bytes;

static VkShaderModule create_shader(VkDevice device, const uint32_t *code, uint32_t bytes) {
    VkShaderModule module = VK_NULL_HANDLE;
    VkShaderModuleCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = bytes,
        .pCode = code,
    };
    VkResult result = vkCreateShaderModule(device, &info, NULL, &module);
    return result == VK_SUCCESS ? module : VK_NULL_HANDLE;
}

bool telar_vulkan_pipeline_init(telar_vulkan_pipeline *self, VkDevice device, VkFormat format) {
    self->device = device;
    self->format = format;
    VkDescriptorSetLayoutBinding bindings[2] = {
        {.binding = 0,
         .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_VERTEX_BIT},
        {.binding = 1,
         .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
         .descriptorCount = 1,
         .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT},
    };
    VkDescriptorSetLayoutCreateInfo set_layout = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 2,
        .pBindings = bindings,
    };
    VK_TRY(vkCreateDescriptorSetLayout(self->device, &set_layout, NULL, &self->set_layout));
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
    VK_TRY(vkCreateDescriptorPool(self->device, &pool, NULL, &self->descriptor_pool));
    VkDescriptorSetAllocateInfo set = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self->descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self->set_layout,
    };
    VK_TRY(vkAllocateDescriptorSets(self->device, &set, &self->descriptors));

    VkPushConstantRange push = {.stageFlags = VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 2 * sizeof(float)};
    VkPipelineLayoutCreateInfo layout = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self->set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push,
    };
    VK_TRY(vkCreatePipelineLayout(self->device, &layout, NULL, &self->layout));

    VkShaderModule vert = create_shader(self->device, telar_gui_quad_vert_spv, telar_gui_quad_vert_spv_bytes);
    if (!vert) {
        return false;
    }
    VkShaderModule frag = create_shader(self->device, telar_gui_quad_frag_spv, telar_gui_quad_frag_spv_bytes);
    if (!frag) {
        vkDestroyShaderModule(self->device, vert, NULL);
        return false;
    }
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_VERTEX_BIT,
         .module = vert,
         .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
         .module = frag,
         .pName = "main"},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {.sType =
                                                             VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
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
        .colorWriteMask =
            VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
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
    VkPipelineRenderingCreateInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &self->format,
    };
    VkGraphicsPipelineCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering,
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
    VK_TRY(vkCreateSampler(self->device, &sampler, NULL, &self->sampler));
    return true;
}

void telar_vulkan_pipeline_deinit(telar_vulkan_pipeline *self) {
    if (self->sampler) {
        vkDestroySampler(self->device, self->sampler, NULL);
    }
    if (self->pipeline) {
        vkDestroyPipeline(self->device, self->pipeline, NULL);
    }
    if (self->layout) {
        vkDestroyPipelineLayout(self->device, self->layout, NULL);
    }
    if (self->descriptor_pool) {
        vkDestroyDescriptorPool(self->device, self->descriptor_pool, NULL);
    }
    if (self->set_layout) {
        vkDestroyDescriptorSetLayout(self->device, self->set_layout, NULL);
    }
    memset(self, 0, sizeof *self);
}
