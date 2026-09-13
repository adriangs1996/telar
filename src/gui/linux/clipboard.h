#ifndef TELAR_CLIPBOARD_H
#define TELAR_CLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <wayland-client.h>

#define TELAR_CLIPBOARD_LIMIT (64 * 1024)
#define TELAR_CLIPBOARD_TRANSFERS 4

typedef struct telar_clipboard telar_clipboard;
typedef struct {
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    uint32_t serial;
    const uint8_t *bytes;
    size_t len;
} telar_clipboard_offer;

telar_clipboard *telar_clipboard_create(void);
void telar_clipboard_destroy(telar_clipboard *);
bool telar_clipboard_publish(telar_clipboard *, const telar_clipboard_offer *);
#endif
