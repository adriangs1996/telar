#pragma once
#include <wayland-client.h>

// Borrowed only during the registry listener call.
typedef struct {
    struct wl_registry *registry;
    uint32_t name, version;
    const char *interface;
} telar_registry_global;
