#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum TelarTestImageFormat {
  telar_test_image_png = 0,
  telar_test_image_tiff = 1,
  telar_test_image_jpeg = 2,
};

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarTestPasteboardCreate(void);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestPasteboardDestroy(void* board);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestPasteboardClear(void* board);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestPasteboardSetSampleImage(void* board, uint8_t format, const uint8_t* rgba_pixels, uint32_t width, uint32_t height);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestPasteboardWritePngFile(const char* path_utf8, const uint8_t* rgba_pixels, uint32_t width, uint32_t height);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestPasteboardSetFileUrl(void* board, const char* path_utf8);

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarTestBytesArePng(const void* bytes, size_t size);

#ifdef __cplusplus
}
#endif
