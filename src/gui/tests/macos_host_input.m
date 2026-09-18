#import "../macos/TelarPointerInputView.h"
#import "../macos/TelarHostServices.h"
#import "../../host/macos/clipboard_image.h"
#import "../macos/TelarAccessibility.h"
#import "../macos/text_ranges.h"
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>

typedef struct {
  telar_gui_text_context text;
  telar_gui_accessibility_node nodes[3];
  telar_gui_accessibility_tree tree;
  telar_gui_host_request requests[8];
  unsigned request_count, request_index, received;
  BOOL reject;
  BOOL context_pending;
  telar_gui_input last;
  uint8_t bytes[64 * 1024];
} host_fixture;

static int receive(void *context, telar_gui_input event) {
  host_fixture *fixture = context;
  if (fixture->reject || event.len > sizeof fixture->bytes) return 0;
  fixture->last = event;
  if (event.len) memcpy(fixture->bytes, event.text, event.len);
  fixture->last.text = fixture->bytes;
  fixture->received++;
  return 1;
}

static int next_request(void *context, telar_gui_host_request *request) {
  host_fixture *fixture = context;
  if (fixture->request_index == fixture->request_count) return 0;
  *request = fixture->requests[fixture->request_index++];
  return 1;
}

static int tree_snapshot(void *context, telar_gui_accessibility_tree *tree) {
  host_fixture *fixture = context;
  *tree = fixture->tree;
  return 1;
}

@interface TelarHostTestView : TelarPointerInputView
@property(nonatomic) host_fixture *fixture;
@end
@implementation TelarHostTestView
- (int)copyTextContext:(telar_gui_text_context *)output {
  if (self.fixture->context_pending) return -1;
  *output = self.fixture->text;
  return YES;
}
@end

@interface TelarScrollTestEvent : NSObject
@end
@implementation TelarScrollTestEvent
- (NSPoint)locationInWindow { return NSMakePoint(13, 17); }
- (NSEventModifierFlags)modifierFlags { return NSEventModifierFlagShift; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (CGFloat)scrollingDeltaX { return 1.25; }
- (CGFloat)scrollingDeltaY { return -2.5; }
- (NSEventPhase)phase { return NSEventPhaseBegan; }
- (NSEventPhase)momentumPhase { return NSEventPhaseEnded; }
@end

static BOOL wait_for(host_fixture *fixture, unsigned count) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:1];
  while (fixture->received < count && end.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  }
  return fixture->received == count;
}

int telar_test_host_input(NSView *host) {
  int failures = 0;
  host_fixture fixture = {0};
  host_fixture *capture = &fixture;
  TelarHostTestView *view = [[TelarHostTestView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)
      inputHandler:^BOOL(telar_gui_input event) { return receive(capture, event); }];
  view.fixture = capture;
  view.hidden = YES;
  [host addSubview:view];
  static const uint8_t surrounding[] = "a\xf0\x9f\x98\x80" "b";
  fixture.text = (telar_gui_text_context){.target_id = 41, .generation = 7, .revision = 1, .enabled = 1,
      .text = surrounding, .len = sizeof surrounding - 1, .selection_start = 1, .selection_end = 5,
      .x = 40, .y = 12, .width = 1, .height = 20};
  [view refreshTextContext];
  if (!NSEqualRanges([view selectedRange], NSMakeRange(1, 2))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  NSRange actual;
  NSAttributedString *substring = [view attributedSubstringForProposedRange:NSMakeRange(1, 2) actualRange:&actual];
  if (![substring.string isEqualToString:@"😀"] || !NSEqualRanges(actual, NSMakeRange(1, 2))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  uint32_t start = 0, end = 0;
  if (!telar_utf8_range(@"a😀b", NSMakeRange(1, 2), &start, &end) || start != 1 || end != 5 ||
      telar_utf8_range(@"a😀b", NSMakeRange(1, 1), &start, &end) ||
      telar_utf16_range(@"a😀b", 2, 5).location != NSNotFound) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  fixture.text.selection_start = 5;
  fixture.text.selection_end = 1;
  fixture.text.revision++;
  [view refreshTextContext];
  if (!NSEqualRanges([view selectedRange], NSMakeRange(1, 2))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view setMarkedText:@"日本" selectedRange:NSMakeRange(1, 1) replacementRange:NSMakeRange(NSNotFound, 0)];
  if (fixture.last.kind != 7 || fixture.last.code != 1 || fixture.last.target_id != 41 || fixture.last.generation != 7 ||
      fixture.last.len != 6 || fixture.last.selection_start != 3 || fixture.last.selection_end != 6 ||
      fixture.last.replacement_start != TELAR_GUI_RANGE_NONE || !NSEqualRanges([view selectedRange], NSMakeRange(2, 1))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view setMarkedText:@"日" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(1, 2)];
  if (fixture.last.replacement_start != 1 || fixture.last.replacement_end != 5 || !NSEqualRanges([view markedRange], NSMakeRange(1, 1))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view insertText:@"é" replacementRange:NSMakeRange(NSNotFound, 0)];
  substring = [view attributedSubstringForProposedRange:NSMakeRange(0, 3) actualRange:&actual];
  if (fixture.last.kind != 1 || fixture.last.target_id != 41 || fixture.last.physical != 0 || fixture.last.len != 2 ||
      fixture.last.replacement_start != TELAR_GUI_RANGE_NONE || [view hasMarkedText] || ![substring.string isEqualToString:@"aéb"]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  NSRect expected = [view.window convertRectToScreen:[view convertRect:telar_content_rect(view, 40, 12, 1, 20) toView:nil]];
  if (!NSEqualRects(expected, [view firstRectForCharacterRange:[view selectedRange] actualRange:&actual])) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view setMarkedText:@"x" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  [view doCommandBySelector:@selector(cancelOperation:)];
  if ([view hasMarkedText] || fixture.last.kind != 7 || fixture.last.code != 2) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view setMarkedText:@"y" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  [view unmarkText];
  if ([view hasMarkedText] || fixture.last.kind != 1 || fixture.last.target_id != 41 || fixture.last.len != 1 || fixture.last.text[0] != 'y') { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view refreshTextContext];
  substring = [view attributedSubstringForProposedRange:NSMakeRange(0, 4) actualRange:&actual];
  if (![substring.string isEqualToString:@"a😀b"]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }

  [view setMarkedText:@"pending" selectedRange:NSMakeRange(7, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  unsigned before_pending = fixture.received;
  fixture.context_pending = YES;
  [view refreshTextContext];
  if (![view hasMarkedText]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  fixture.context_pending = NO;
  fixture.text.composition_active = 1;
  [view refreshTextContext];
  if (![view hasMarkedText]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  fixture.text.composition_active = 0;
  [view refreshTextContext];
  if ([view hasMarkedText] || fixture.received != before_pending) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }

  [view setMarkedText:@"pending" selectedRange:NSMakeRange(7, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  unsigned before_owner_change = fixture.received;
  fixture.text.generation++;
  [view refreshTextContext];
  if ([view hasMarkedText] || fixture.received != before_owner_change) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }

  [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0
      windowNumber:view.window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
  if (fixture.last.kind != 4 || fixture.last.code != 'a' || fixture.last.mods != 8 || fixture.last.target_id != 41) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view releasePressedKeys];
  fixture.text = (telar_gui_text_context){0};
  [view refreshTextContext];
  unsigned before_terminal_preedit = fixture.received;
  [view setMarkedText:@"日本" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  [view refreshTextContext];
  if (![view hasMarkedText] || fixture.received != before_terminal_preedit) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view insertText:@"日本語" replacementRange:NSMakeRange(NSNotFound, 0)];
  if ([view hasMarkedText] || fixture.last.kind != 1 || fixture.last.target_id != 0 || fixture.last.len != 9 ||
      memcmp(fixture.last.text, "日本語", 9)) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [view scrollWheel:(NSEvent *)[TelarScrollTestEvent new]];
  const double scale = view.window.backingScaleFactor;
  if (fixture.last.kind != 8 || fixture.last.mods != 1 || fixture.last.precise != 1 || fixture.last.scroll_phase != 1 || fixture.last.momentum_phase != 3 ||
      fixture.last.delta_x != -1.25 * scale || fixture.last.delta_y != 2.5 * scale) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }

  const telar_gui_callbacks callbacks = {.input = receive, .host_request = next_request, .accessibility = tree_snapshot};
  fixture.nodes[0] = (telar_gui_accessibility_node){.id = 1, .generation = 1, .role = 1, .flags = 1, .width = 300, .height = 100};
  fixture.nodes[1] = (telar_gui_accessibility_node){.id = 2, .generation = 1, .parent_id = 1, .role = 2, .flags = 1, .actions = 3,
      .width = 20, .height = 20, .label = (const uint8_t *)"Action", .label_len = 6};
  fixture.nodes[2] = (telar_gui_accessibility_node){.id = 3, .generation = 1, .parent_id = 1, .role = 3, .flags = 11, .actions = 14,
      .x = 25, .width = 200, .height = 20, .label = (const uint8_t *)"Name", .label_len = 4,
      .value = surrounding, .value_len = sizeof surrounding - 1, .selection_start = 5, .selection_end = 1, .text_revision = 70};
  fixture.tree = (telar_gui_accessibility_tree){.revision = 1, .nodes = fixture.nodes, .count = 3};
  TelarAccessibility *accessibility = [[TelarAccessibility alloc] initWithView:view context:capture callbacks:&callbacks];
  [accessibility refresh];
  NSArray *children = [[accessibility children].firstObject accessibilityChildren];
  if (children.count != 2) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  id button = children.firstObject;
  id field = children.lastObject;
  if (![button accessibilityPerformPress] || fixture.last.kind != 10 || fixture.last.code != 1 || fixture.last.target_id != 2) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  if ([accessibility focusedElement] != field || !NSEqualRanges([field accessibilitySelectedTextRange], NSMakeRange(1, 2))) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [field setAccessibilityValue:@"mañana"];
  if (fixture.last.code != 4 || fixture.last.len != 7 || fixture.last.revision != 70) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  fixture.nodes[2].text_revision = 71;
  fixture.tree.revision++;
  [field setAccessibilitySelectedTextRange:NSMakeRange(1, 2)];
  if (fixture.last.code != 8 || fixture.last.selection_start != 1 || fixture.last.selection_end != 5 || fixture.last.revision != 70) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [accessibility refresh];
  [field setAccessibilitySelectedTextRange:NSMakeRange(1, 2)];
  if (fixture.last.revision != 71) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  fixture.nodes[1] = fixture.nodes[2];
  fixture.tree.count = 2;
  fixture.tree.revision++;
  [accessibility refresh];
  if ([button accessibilityPerformPress]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [accessibility stop];

  NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
  TelarHostServices *services = [[TelarHostServices alloc] initWithContext:capture callbacks:&callbacks pasteboard:pasteboard];
  uint8_t clipboard[] = "owned clipboard";
  fixture.requests[0] = (telar_gui_host_request){.kind = 2, .request_id = 101, .target_id = 41, .generation = 7, .text = clipboard, .len = sizeof clipboard - 1};
  fixture.requests[1] = (telar_gui_host_request){.kind = 1, .request_id = 102, .target_id = 41, .generation = 7};
  fixture.request_count = 2;
  unsigned before = fixture.received;
  [services drain];
  memset(clipboard, 'x', sizeof clipboard - 1);
  if (!wait_for(capture, before + 1) || fixture.last.kind != 9 || fixture.last.code != 0 || fixture.last.request_id != 101 ||
      ![[pasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"owned clipboard"]) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  before = fixture.received;
  fixture.reject = YES;
  [services drain];
  [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  fixture.reject = NO;
  [services drain];
  if (!wait_for(capture, before + 1) || fixture.last.request_id != 102 || fixture.last.target_id != 41 || fixture.last.generation != 7 ||
      fixture.last.len != 15 || memcmp(fixture.last.text, "owned clipboard", 15)) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [pasteboard clearContents];
  [pasteboard setString:[@"" stringByPaddingToLength:64 * 1024 + 1 withString:@"x" startingAtIndex:0] forType:NSPasteboardTypeString];
  fixture.requests[2] = (telar_gui_host_request){.kind = 1, .request_id = 103, .target_id = 41, .generation = 7};
  fixture.request_count = 3;
  before = fixture.received;
  [services drain];
  if (!wait_for(capture, before + 1) || fixture.last.code != 2 || fixture.last.request_id != 103 || fixture.last.len != 0) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  [pasteboard clearContents];
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:8 pixelsHigh:8 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:32 bitsPerPixel:32];
  arc4random_buf(bitmap.bitmapData, 256);
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  [pasteboard setData:png forType:NSPasteboardTypePNG];
  [pasteboard setString:@"Image caption must not become the attachment" forType:NSPasteboardTypeString];
  unsigned char *limited_bytes = NULL;
  size_t limited_length = 0;
  uint32_t limited_width = 0, limited_height = 0;
  if (telar_clipboard_copy_png(pasteboard, &limited_bytes, &limited_length, &limited_width, &limited_height, png.length - 1, 1024 * 1024, 64) != TELAR_CLIPBOARD_TOO_LARGE || limited_bytes != NULL) { fprintf(stderr, "image source quota failed\n"); failures++; }
  if (telar_clipboard_copy_png(pasteboard, &limited_bytes, &limited_length, &limited_width, &limited_height, 1024 * 1024, 1024 * 1024, 63) != TELAR_CLIPBOARD_TOO_LARGE || limited_bytes != NULL) { fprintf(stderr, "image pixel quota failed\n"); failures++; }
  if (telar_clipboard_copy_png(pasteboard, &limited_bytes, &limited_length, &limited_width, &limited_height, 1024 * 1024, 1, 64) != TELAR_CLIPBOARD_TOO_LARGE || limited_bytes != NULL) { fprintf(stderr, "image PNG quota failed\n"); failures++; }
  fixture.requests[3] = (telar_gui_host_request){.kind = 3, .request_id = 105, .target_id = 41, .generation = 7};
  fixture.request_count = 4;
  before = fixture.received;
  [services drain];
  if (!wait_for(capture, before + 1) || fixture.last.code != 4 || fixture.last.request_id != 105) { fprintf(stderr, "image clipboard capture failed at line %d\n", __LINE__); failures++; }
  NSString *image_path = [[NSString alloc] initWithBytes:fixture.last.text length:fixture.last.len encoding:NSUTF8StringEncoding];
  NSBitmapImageRep *saved = [NSBitmapImageRep imageRepWithContentsOfFile:image_path];
  if (saved.pixelsWide != 8 || saved.pixelsHigh != 8) { fprintf(stderr, "image clipboard dimensions failed at line %d\n", __LINE__); failures++; }
  struct stat image_info;
  if (image_path.length == 0 || lstat(image_path.fileSystemRepresentation, &image_info) != 0 || (image_info.st_mode & 077) != 0) { fprintf(stderr, "image clipboard permissions failed at line %d\n", __LINE__); failures++; }
  [pasteboard clearContents];
  [pasteboard setString:@"ordinary text" forType:NSPasteboardTypeString];
  fixture.requests[4] = (telar_gui_host_request){.kind = 3, .request_id = 106, .target_id = 41, .generation = 7};
  fixture.request_count = 5;
  before = fixture.received;
  [services drain];
  if (!wait_for(capture, before + 1) || fixture.last.code != 0 || fixture.last.len != 13 || memcmp(fixture.last.text, "ordinary text", 13)) { fprintf(stderr, "image clipboard text fallback failed at line %d\n", __LINE__); failures++; }
  fixture.requests[5] = (telar_gui_host_request){.kind = 3, .request_id = 104, .target_id = 41, .generation = 7};
  fixture.request_count = 6;
  before = fixture.received;
  [services drain];
  [services stop];
  [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  if (fixture.received != before) { fprintf(stderr, "native host input assertion failed at line %d\n", __LINE__); failures++; }
  if (![NSFileManager.defaultManager fileExistsAtPath:image_path]) { fprintf(stderr, "image must outlive GUI service shutdown\n"); failures++; }
  [NSFileManager.defaultManager removeItemAtPath:image_path error:NULL];
  [pasteboard releaseGlobally];
  [view stopInput];
  [view removeFromSuperview];
  fprintf(stdout, "native host input: preedit, UTF-8 ranges, caret, Command, precise scroll, AX and clipboard failures=%d\n", failures);
  return failures;
}
