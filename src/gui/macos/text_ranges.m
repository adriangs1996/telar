#import "text_ranges.h"
#include <math.h>

static NSUInteger utf16_offset(NSString *text, uint32_t offset) {
  uint32_t bytes = 0;
  for (NSUInteger index = 0; index < text.length; index++) {
    if (bytes == offset) return index;
    unichar current = [text characterAtIndex:index];
    if (CFStringIsSurrogateHighCharacter(current)) {
      if (index + 1 >= text.length || !CFStringIsSurrogateLowCharacter([text characterAtIndex:index + 1])) return NSNotFound;
      bytes += 4;
      index++;
    } else if (CFStringIsSurrogateLowCharacter(current)) {
      return NSNotFound;
    } else {
      bytes += current < 0x80 ? 1 : current < 0x800 ? 2 : 3;
    }
    if (bytes > offset) return NSNotFound;
  }
  return bytes == offset ? text.length : NSNotFound;
}

NSRange telar_utf16_range(NSString *text, uint32_t start, uint32_t end) {
  if (start > end) {
    uint32_t anchor = start;
    start = end;
    end = anchor;
  }
  NSUInteger first = utf16_offset(text, start), last = utf16_offset(text, end);
  if (first == NSNotFound || last == NSNotFound) return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(first, last - first);
}

BOOL telar_utf8_range(NSString *text, NSRange range, uint32_t *start, uint32_t *end) {
  if (range.location == NSNotFound || range.location > text.length || range.length > text.length - range.location) return NO;
  CFIndex first = 0, last = 0;
  CFStringRef string = (__bridge CFStringRef)text;
  if (CFStringGetBytes(string, CFRangeMake(0, range.location), kCFStringEncodingUTF8, 0, false, NULL, 0, &first) != (CFIndex)range.location ||
      CFStringGetBytes(string, CFRangeMake(0, NSMaxRange(range)), kCFStringEncodingUTF8, 0, false, NULL, 0, &last) != (CFIndex)NSMaxRange(range) || last > UINT32_MAX) return NO;
  *start = (uint32_t)first;
  *end = (uint32_t)last;
  return YES;
}

NSRect telar_content_rect(NSView *view, double x, double y, double width, double height) {
  CGFloat scale = view.window != nil ? view.window.backingScaleFactor : 1;
  if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || scale <= 0) return NSZeroRect;
  NSRect rect = NSMakeRect(x / scale, y / scale, fmax(0, width) / scale, fmax(0, height) / scale);
  if (!view.isFlipped) rect.origin.y = view.bounds.size.height - NSMaxY(rect);
  return rect;
}
