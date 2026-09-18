#pragma once
#import <AppKit/AppKit.h>

// Runs on the media queue. Returns a private immutable PNG path, or a clipboard
// status. The cache survives client shutdown so accepted runtime turns retain it.
NSData *telar_clipboard_image_path(NSPasteboard *pasteboard, uint32_t *status);
