#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum TelarGuiClipboardStatus {
  telar_gui_clipboard_ok = 0,
  telar_gui_clipboard_no_image = 1,
  telar_gui_clipboard_changed = 2,
  telar_gui_clipboard_source_bytes = 3,
  telar_gui_clipboard_png_bytes = 4,
  telar_gui_clipboard_pixels = 5,
  telar_gui_clipboard_invalid_image = 6,
  telar_gui_clipboard_read_failed = 7,
  telar_gui_clipboard_bad_alloc = 8,
};

typedef size_t (*TelarGuiClipboardWriteCallback)(void* context, const void* bytes, size_t size);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarGuiClipboardGeneralPasteboard(int64_t* revision);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarGuiClipboardRetainPasteboard(void* pasteboard, int64_t* revision);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarGuiClipboardReleasePasteboard(void* native);

#ifdef __cplusplus
[[tbc::raw]]
#endif
uint8_t telarGuiClipboardReadPng(
    void* native,
    int64_t revision,
    uint64_t max_source_bytes,
    uint64_t max_pixels,
    TelarGuiClipboardWriteCallback write_callback,
    void* write_context,
    uint32_t* width,
    uint32_t* height
);

#ifdef __cplusplus
}
#endif
