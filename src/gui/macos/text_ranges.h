#pragma once
#import <AppKit/AppKit.h>
#include <stdint.h>

// UTF-8 offsets cross the ABI; Cocoa ranges count UTF-16 code units.
NSRange telar_utf16_range(NSString *text, uint32_t start, uint32_t end);
BOOL telar_utf8_range(NSString *text, NSRange range, uint32_t *start, uint32_t *end);
NSRect telar_content_rect(NSView *view, double x, double y, double width, double height);
