#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum TelarTestClipboardImageFormat {
  telar_test_clipboard_png = 0,
  telar_test_clipboard_tiff = 1,
  telar_test_clipboard_jpeg = 2,
} TelarTestClipboardImageFormat;

typedef void (*TelarTestClipboardBytesCallback)(void* context, const unsigned char* bytes, size_t size);

bool telarTestClipboardSetUtf8(const char* utf8, size_t size);
bool telarTestClipboardSetEncodedImage(uint8_t format, bool also_set_text, TelarTestClipboardBytesCallback on_encoded, void* context);
bool telarTestClipboardSetUnsupported(void);

#ifdef __cplusplus
}
#endif
