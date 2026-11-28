#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
enum class TelarGuiClipboardStatus : uint8_t {
#else
enum TelarGuiClipboardStatus {
#endif
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

#ifdef __cplusplus
inline constexpr auto telar_gui_clipboard_ok = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_ok);
inline constexpr auto telar_gui_clipboard_no_image = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_no_image);
inline constexpr auto telar_gui_clipboard_changed = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_changed);
inline constexpr auto telar_gui_clipboard_source_bytes = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_source_bytes);
inline constexpr auto telar_gui_clipboard_png_bytes = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_png_bytes);
inline constexpr auto telar_gui_clipboard_pixels = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_pixels);
inline constexpr auto telar_gui_clipboard_invalid_image = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_invalid_image);
inline constexpr auto telar_gui_clipboard_read_failed = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_read_failed);
inline constexpr auto telar_gui_clipboard_bad_alloc = static_cast<uint8_t>(TelarGuiClipboardStatus::telar_gui_clipboard_bad_alloc);
#endif

typedef size_t (*TelarGuiClipboardWriteCallback)(void* context, const void* bytes, size_t size);

typedef struct TelarGuiClipboardDimensions {
  uint32_t width;
  uint32_t height;
} TelarGuiClipboardDimensions;

typedef struct TelarGuiClipboardReadRequest {
  int64_t revision;
  uint64_t max_source_bytes;
  uint64_t max_pixels;
  TelarGuiClipboardWriteCallback write_callback;
  void* write_context;
} TelarGuiClipboardReadRequest;

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarGuiClipboardGeneralPasteboard(int64_t* revision);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarGuiClipboardRetainPasteboard(const void* pasteboard, int64_t* revision);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarGuiClipboardReleasePasteboard(const void* native);

#ifdef __cplusplus
[[tbc::raw]]
#endif
uint8_t telarGuiClipboardReadPng(
    const void* native,
    const TelarGuiClipboardReadRequest* request,
    TelarGuiClipboardDimensions* dimensions
);

#ifdef __cplusplus
}
#endif
