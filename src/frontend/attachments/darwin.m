#import "../../host/macos/clipboard_image.h"

int telar_macos_clipboard_copy_png(unsigned char **bytes, size_t *len, uint32_t *width, uint32_t *height, size_t max_source_bytes, size_t max_png_bytes, uint64_t max_pixels) {
    return telar_clipboard_copy_png(NSPasteboard.generalPasteboard, bytes, len, width, height, max_source_bytes, max_png_bytes, max_pixels);
}
