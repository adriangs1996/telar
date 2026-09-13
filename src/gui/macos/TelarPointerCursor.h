#pragma once
#import <AppKit/AppKit.h>
#include <stdint.h>

// Canonical core.PointerShape values, e.g. [telar_pointer_cursor(8) set].
// Main-thread only. Cursors are retained once; motion and frame updates allocate
// no cursor objects.
NSCursor *telar_pointer_cursor(uint32_t shape);
