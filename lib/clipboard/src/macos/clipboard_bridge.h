#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
enum class TelarClipboardStatus : uint8_t {
#else
enum TelarClipboardStatus {
#endif
  telar_clipboard_ok = 0,
  telar_clipboard_no_supported_content = 1,
  telar_clipboard_encoding_failed = 2,
  telar_clipboard_changed = 3,
  telar_clipboard_allocation_failed = 4,
  telar_clipboard_content_too_large = 5,
};

#ifdef __cplusplus
inline constexpr auto telar_clipboard_ok = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_ok);
inline constexpr auto telar_clipboard_no_supported_content = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_no_supported_content);
inline constexpr auto telar_clipboard_encoding_failed = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_encoding_failed);
inline constexpr auto telar_clipboard_changed = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_changed);
inline constexpr auto telar_clipboard_allocation_failed = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_allocation_failed);
inline constexpr auto telar_clipboard_content_too_large = static_cast<uint8_t>(TelarClipboardStatus::telar_clipboard_content_too_large);
#endif

typedef uint8_t (*TelarClipboardStoreCallback)(
    void* context,
    const char* mime_literal,
    const unsigned char* bytes,
    size_t size
);

uint8_t telarClipboardMacosRead(
    size_t maximum_bytes,
    TelarClipboardStoreCallback store,
    void* context
);

#ifdef __cplusplus
}
#endif
