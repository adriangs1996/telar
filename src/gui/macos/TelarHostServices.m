#import "TelarHostServices.h"
#import "TelarClipboardImage.h"

@implementation TelarHostServices {
  void *context;
  telar_gui_callbacks callbacks;
  NSPasteboard *pasteboard;
  BOOL busy, closed, completion_ready;
  telar_gui_input completion;
  NSData *completion_bytes;
}

- (instancetype)initWithContext:(void *)value callbacks:(const telar_gui_callbacks *)table pasteboard:(NSPasteboard *)board {
  self = [super init];
  if (self != nil) {
    context = value;
    callbacks = *table;
    pasteboard = board;
  }
  return self;
}

- (void)deliver {
  if (closed || !completion_ready || callbacks.input == NULL) return;
  completion.text = completion_bytes.bytes;
  completion.len = completion_bytes.length;
  if (!callbacks.input(context, completion)) return;
  completion_bytes = nil;
  completion_ready = NO;
  busy = NO;
}

- (void)drain {
  if (closed) return;
  [self deliver];
  if (busy || callbacks.host_request == NULL) return;
  telar_gui_host_request request = {0};
  if (!callbacks.host_request(context, &request)) return;
  busy = YES;
  const uint64_t request_id = request.request_id, target_id = request.target_id, generation = request.generation;
  const uint32_t kind = request.kind;
  const BOOL invalid = request.len > 64 * 1024 || (request.len && request.text == NULL);
  NSData *owned = !invalid && kind == 2 ? [NSData dataWithBytes:request.text length:request.len] : nil;
  __weak TelarHostServices *weak = self;
  // AppKit pasteboard access stays on the main thread, outside input dispatch.
  // Only one operation and its bounded result can be queued at a time.
  [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
    TelarHostServices *service = weak;
    if (service == nil || service->closed) return;
    if (!invalid && kind == 3) {
      // One owned media job; no GUI pointer or borrowed input bytes reach it.
      NSPasteboard *board = service->pasteboard;
      const NSInteger change_count = board.changeCount;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
          uint32_t image_status = 0;
          NSData *image_path = telar_clipboard_image_path(board, &image_status);
          [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
            TelarHostServices *owner = weak;
            if (owner == nil || owner->closed) return;
            uint32_t status = image_path != nil ? 4 : image_status;
            NSData *result = image_path;
            if (owner->pasteboard.changeCount != change_count) {
              status = 3;
              result = nil;
            } else if (image_status == 1) {
              NSString *text = [owner->pasteboard stringForType:NSPasteboardTypeString];
              if (text == nil) status = 1;
              else if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 * 1024) status = 2;
              else {
                result = [text dataUsingEncoding:NSUTF8StringEncoding];
                status = result != nil ? 0 : 1;
              }
            }
            owner->completion = (telar_gui_input){.kind = 9, .code = status, .phase = 1,
                .request_id = request_id, .target_id = target_id, .generation = generation};
            owner->completion_bytes = result;
            owner->completion_ready = YES;
            [owner deliver];
          }];
          CFRunLoopWakeUp(CFRunLoopGetMain());
        }
      });
      return;
    }
    uint32_t status = invalid ? 2 : 0;
    NSData *result = nil;
    if (!invalid && kind == 1) {
      NSString *text = [service->pasteboard stringForType:NSPasteboardTypeString];
      if (text == nil) status = 1;
      else if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 64 * 1024) status = 2;
      else {
        result = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (result == nil) status = 1;
      }
    } else if (!invalid && kind == 2) {
      NSString *text = [[NSString alloc] initWithData:owned encoding:NSUTF8StringEncoding];
      if (text == nil) status = 1;
      else {
        [service->pasteboard clearContents];
        if (![service->pasteboard setString:text forType:NSPasteboardTypeString]) status = 1;
      }
    } else if (!invalid) status = 1;
    service->completion = (telar_gui_input){.kind = 9, .code = status, .phase = 1,
        .request_id = request_id, .target_id = target_id, .generation = generation};
    service->completion_bytes = result;
    service->completion_ready = YES;
    [service deliver];
  }];
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)stop {
  closed = YES;
  context = NULL;
  completion_bytes = nil;
  callbacks = (telar_gui_callbacks){0};
}
@end
