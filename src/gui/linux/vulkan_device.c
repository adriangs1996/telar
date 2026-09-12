#include "vulkan_device.h"
#include <string.h>

static bool create_instance(telar_vulkan_device *self, struct wl_display *display, struct wl_surface *surface) {
    const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
                                VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME,
                                VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME};
    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "telar",
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = 4,
        .ppEnabledExtensionNames = extensions,
    };
    VK_TRY(vkCreateInstance(&info, NULL, &self->instance));
    VkWaylandSurfaceCreateInfoKHR surface_info = {
        .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = display,
        .surface = surface,
    };
    VK_TRY(vkCreateWaylandSurfaceKHR(self->instance, &surface_info, NULL, &self->surface));
    return true;
}

static bool pick_device(telar_vulkan_device *self) {
    uint32_t count = 0;
    VK_TRY(vkEnumeratePhysicalDevices(self->instance, &count, NULL));
    if (count == 0) {
        fprintf(stderr, "telar gui: no Vulkan device\n");
        return false;
    }
    if (count > 16) {
        count = 16;
    }
    VkPhysicalDevice devices[16];
    VK_TRY(vkEnumeratePhysicalDevices(self->instance, &count, devices));
    for (uint32_t d = 0; d < count; d++) {
        VkPhysicalDeviceProperties device_properties;
        vkGetPhysicalDeviceProperties(devices[d], &device_properties);
        if (device_properties.apiVersion < VK_API_VERSION_1_3) {
            continue;
        }
        VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT maintenance = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
        };
        VkPhysicalDeviceVulkan13Features modern = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = &maintenance,
        };
        VkPhysicalDeviceFeatures2 features = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &modern,
        };
        vkGetPhysicalDeviceFeatures2(devices[d], &features);
        if (!modern.dynamicRendering || !modern.synchronization2 || !maintenance.swapchainMaintenance1) {
            continue;
        }
        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, NULL);
        if (families > 16) {
            families = 16;
        }
        VkQueueFamilyProperties properties[16];
        vkGetPhysicalDeviceQueueFamilyProperties(devices[d], &families, properties);
        for (uint32_t f = 0; f < families; f++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(devices[d], f, self->surface, &present);
            if ((properties[f].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                self->physical = devices[d];
                self->queue_family = f;
                self->limits = device_properties.limits;
                vkGetPhysicalDeviceMemoryProperties(self->physical, &self->memory);
                return true;
            }
        }
    }
    fprintf(stderr, "telar gui: requires Vulkan 1.3, dynamicRendering, synchronization2, swapchainMaintenance1 and a "
                    "graphics/present queue\n");
    return false;
}

static bool create_device(telar_vulkan_device *self) {
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = self->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const char *extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME};
    VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT maintenance = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
        .swapchainMaintenance1 = VK_TRUE,
    };
    VkPhysicalDeviceVulkan13Features modern = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .pNext = &maintenance,
        .dynamicRendering = VK_TRUE,
        .synchronization2 = VK_TRUE,
    };
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &modern,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = extensions,
    };
    VK_TRY(vkCreateDevice(self->physical, &info, NULL, &self->device));
    vkGetDeviceQueue(self->device, self->queue_family, 0, &self->queue);

    return true;
}

bool telar_vulkan_device_init(telar_vulkan_device *self, struct wl_display *display, struct wl_surface *surface) {
    return create_instance(self, display, surface) && pick_device(self) && create_device(self);
}

uint32_t telar_vulkan_memory_type(const telar_vulkan_device *self, uint32_t bits, VkMemoryPropertyFlags wanted) {
    for (uint32_t i = 0; i < self->memory.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (self->memory.memoryTypes[i].propertyFlags & wanted) == wanted) {
            return i;
        }
    }
    return UINT32_MAX;
}

void telar_vulkan_device_deinit(telar_vulkan_device *self) {
    if (self->device) {
        vkDestroyDevice(self->device, NULL);
    }
    if (self->surface) {
        vkDestroySurfaceKHR(self->instance, self->surface, NULL);
    }
    if (self->instance) {
        vkDestroyInstance(self->instance, NULL);
    }
    memset(self, 0, sizeof *self);
}
