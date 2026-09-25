#import "TelarHostServices.h"

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
