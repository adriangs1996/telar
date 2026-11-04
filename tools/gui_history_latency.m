#include "gui_view.h"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <stdatomic.h>

enum { PixelBytes = 4,
       BufferCount = 3,
       MaximumDiagnosticFrames = 512 };
static NSUInteger ProbeWidth, ProbeHeight, RegionX, RegionY, RegionWidth, RegionHeight, readback_pitch;
static NSSize viewport;
static NSString *queries[2];
static double overall_timeout;
static const double QueryTimeoutSeconds = 2;
static const double CallbackDrainSeconds = .05;
static const int64_t DriverTickNanoseconds = 5 * NSEC_PER_MSEC;

@interface HistoryReadback : NSObject
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) id<MTLResidencySet> residency;
@property(nonatomic, strong) id<MTLTexture> residentTexture;
@end
@implementation HistoryReadback
@end

@interface HistoryFrame : NSObject
@property(nonatomic) NSUInteger drawableID;
@property(nonatomic) MTLPixelFormat format;
@property(nonatomic) double presentedTime;
@property(nonatomic) double committedTime;
@property(nonatomic) double completedTime;
@property(nonatomic) double gpuWork;
@property(nonatomic, strong) NSData *pixels;
@property(nonatomic) BOOL receivedPresentation;
@property(nonatomic) BOOL verified;
@property(nonatomic) BOOL recorded;
@property(nonatomic) BOOL submitted;
@property(nonatomic, strong) NSString *matched;
@end
@implementation HistoryFrame
@end

@interface HistorySubmission : NSObject
@property(nonatomic, strong) HistoryFrame *frame;
@property(nonatomic, strong) HistoryReadback *slot;
@property(nonatomic, strong) id<MTLTexture> texture;
@end
@implementation HistorySubmission
@end

static IMP original_next, original_encoder, original_commit, original_encoder4, original_end4, original_commit4, original_layer;
static char frame_key, command_texture_key, readback_key;
static NSMutableArray<HistoryReadback *> *slots;
static NSData *templates[2];
static NSString *destination;
static NSMutableArray *observations;
static NSUInteger presented_count, zero_count, dropped_count;
static BOOL timing, finished, started, ready;
static NSString *settled_path, *last_match, *expected_query, *ready_path, *release_path;
static NSMutableArray *trials;
static NSUInteger requested_trials, phase;
static double phase_started, input_time, query_start_time, earliest_presentation;
static double latest_presentation;
static NSString *latest_match;
static NSUInteger earliest_drawable, ignored_old, ignored_zero, zero_new;
static NSString *negative_control;
static BOOL callback_suppressed;
static BOOL late_stale_injected;
static BOOL diagnostic;
static NSMutableArray *diagnostic_frames;
static _Atomic bool measuring;
static _Atomic NSUInteger pending_submissions;
static _Atomic uint64_t commit_hook_ns, completion_hook_ns, record_hook_ns, encoder_hook_ns, drawable_hook_ns, tick_hook_ns, copy_count;
static double gpu_work_total, gpu_work_max;
static NSUInteger measured_frames;
static double burst_interval, burst_stall, minimum_query_interval, callback_drain = CallbackDrainSeconds;
static NSMutableArray *burst_inputs;
static _Atomic bool display_sync;
static _Atomic NSUInteger maximum_drawables;

static void add_probe_time(_Atomic uint64_t *counter, double before) {
  if (atomic_load(&measuring)) {
    atomic_fetch_add(counter, (uint64_t)((CACurrentMediaTime() - before) * 1e9));
  }
}

static void finish_timing(NSString *error) {
  if (finished) {
    return;
  }
  finished = YES;
  atomic_store(&measuring, false);
  if (diagnostic) {
    NSString *folder = [destination stringByAppendingString:@".frames"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:nil]) {
      abort();
    }
    NSMutableArray *timeline = [NSMutableArray array];
    for (HistoryFrame *frame in diagnostic_frames) {
      NSString *name = [NSString stringWithFormat:@"%lu.bgra", frame.drawableID];
      if (![frame.pixels writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES]) {
        abort();
      }
      [timeline addObject:@{@"drawable_id" : @(frame.drawableID),
                            @"committed_time" : @(frame.committedTime),
                            @"completed_time" : @(frame.completedTime),
                            @"presented_time" : @(frame.presentedTime),
                            @"matched" : frame.matched,
                            @"pixels" : name}];
    }
    NSData *timeline_json = [NSJSONSerialization dataWithJSONObject:timeline options:NSJSONWritingPrettyPrinted error:nil];
    if (![timeline_json writeToFile:[folder stringByAppendingPathComponent:@"timeline.json"] atomically:YES]) {
      abort();
    }
  }
  NSDictionary *report = @{@"passed" : @(!error),
                           @"performance_eligible" : @NO,
                           @"scope" : @"Native query replacement observer qualification; instrumentation overhead not yet qualified",
                           @"error" : error ?: @"",
                           @"trials" : trials,
                           @"burst_interval_ms" : @(burst_interval * 1000),
                           @"burst_producer" : burst_interval > 0 ? @"strict-timer-user-interactive" : @"disabled",
                           @"burst_main_stall_ms" : @(burst_stall * 1000),
                           @"minimum_query_interval_ms" : @(minimum_query_interval * 1000),
                           @"negative_control" : negative_control ?: @"",
                           @"presented_count" : @(presented_count),
                           @"zero_count" : @(zero_count),
                           @"dropped_count" : @(dropped_count),
                           @"ignored_old_result_frames" : @(ignored_old),
                           @"ignored_zero_frames_during_trial" : @(ignored_zero),
                           @"zero_new_result_frames" : @(zero_new),
                           @"observer_commit_elapsed_ns" : @(atomic_load(&commit_hook_ns)),
                           @"observer_completion_elapsed_ns" : @(atomic_load(&completion_hook_ns)),
                           @"observer_record_elapsed_ns" : @(atomic_load(&record_hook_ns)),
                           @"observer_encoder_elapsed_ns" : @(atomic_load(&encoder_hook_ns)),
                           @"observer_drawable_elapsed_ns" : @(atomic_load(&drawable_hook_ns)),
                           @"observer_tick_elapsed_ns" : @(atomic_load(&tick_hook_ns)),
                           @"pending_submissions" : @(atomic_load(&pending_submissions)),
                           @"callback_suppressed" : @(callback_suppressed),
                           @"late_stale_injected" : @(late_stale_injected),
                           @"last_trial_had_verified_result" : @(earliest_presentation > 0),
                           @"observer_buffer_bytes" : @(BufferCount * readback_pitch * RegionHeight),
                           @"observer_copies" : @(atomic_load(&copy_count)),
                           @"verified_trial_frames" : @(measured_frames),
                           @"render_submission_gpu_total_ms" : @(gpu_work_total * 1000),
                           @"render_submission_gpu_max_ms" : @(gpu_work_max * 1000),
                           @"display_sync" : @(atomic_load(&display_sync)),
                           @"maximum_drawables" : @(atomic_load(&maximum_drawables)),
                           @"screen_maximum_fps" : @(NSApp.keyWindow.screen.maximumFramesPerSecond),
                           @"screen_scale" : @(NSApp.keyWindow.backingScaleFactor),
                           @"screen_id" : NSApp.keyWindow.screen.deviceDescription[@"NSScreenNumber"] ?: @0};
  NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  if (![json writeToFile:destination atomically:YES]) {
    abort();
  }
}

static NSString *input_text(NSView *view) {
  if (![view respondsToSelector:@selector(attributedSubstringForProposedRange:actualRange:)]) {
    return @"";
  }
  NSRange actual = NSMakeRange(NSNotFound, 0);
  NSAttributedString *value = [(id<NSTextInputClient>)view attributedSubstringForProposedRange:NSMakeRange(0, 128) actualRange:&actual];
  return value.string ?: @"";
}

static void select_query(NSView *view) {
  for (NSNumber *kind in @[ @(NSEventTypeKeyDown), @(NSEventTypeKeyUp) ]) {
    NSEvent *event = [NSEvent keyEventWithType:kind.unsignedIntegerValue
                                      location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand
                                     timestamp:CACurrentMediaTime()
                                  windowNumber:view.window.windowNumber
                                       context:nil
                                    characters:@"a"
                   charactersIgnoringModifiers:@"a"
                                     isARepeat:NO
                                       keyCode:0];
    [NSApp postEvent:event atStart:NO];
  }
}

static void offer_burst(NSView *view) {
  NSMutableArray<NSString *> *characters = [NSMutableArray array];
  [expected_query enumerateSubstringsInRange:NSMakeRange(0, expected_query.length)
                                   options:NSStringEnumerationByComposedCharacterSequences
                                usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
                                  [characters addObject:substring];
                                }];
  burst_inputs = [NSMutableArray arrayWithCapacity:characters.count];
  phase = 3;
  dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
  dispatch_queue_t producer = dispatch_queue_create("telar.history-burst-producer", attributes);
  __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, producer);
  if (!timer) {
    finish_timing(@"Burst producer timer is unavailable");
    return;
  }

  const double began = CACurrentMediaTime();
  const dispatch_time_t origin = dispatch_time(DISPATCH_TIME_NOW, 0);
  __block NSUInteger next_character = 0;
  dispatch_source_set_event_handler(timer, ^{
    const NSUInteger index = next_character++;
    NSString *character = characters[index];
    const double offset = index * burst_interval;
    const double enqueued = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
      if (finished) {
        return;
      }
      if (terminal_view(NSApp.keyWindow.contentView) != view || !NSApp.isActive || !view.window.isKeyWindow || !NSEqualSizes(view.bounds.size, viewport)) {
        finish_timing(@"Native focus or geometry changed during burst");
        return;
      }
      const double delivered = CACurrentMediaTime();
      if (index == 0) {
        query_start_time = delivered;
      }

      if (index + 1 == characters.count) {
        phase = 2;
        phase_started = delivered;
        input_time = delivered;
      }

      [(id<NSTextInputClient>)view insertText:character replacementRange:NSMakeRange(NSNotFound, 0)];
      [burst_inputs addObject:@{@"text" : character, @"offered_time" : @(began + offset), @"enqueued_time" : @(enqueued),
                               @"delivered_time" : @(delivered), @"input_text" : input_text(view)}];
      if (index + 1 == characters.count && ![input_text(view) isEqualToString:expected_query]) {
        finish_timing(@"Native burst did not produce the expected text");
      }
    });

    if (next_character == characters.count) {
      dispatch_source_cancel(timer);
      timer = nil;
    } else {
      dispatch_source_set_timer(timer, dispatch_time(origin, (int64_t)(next_character * burst_interval * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    }
  });
  dispatch_source_set_timer(timer, origin, DISPATCH_TIME_FOREVER, 0);
  dispatch_resume(timer);
  if (burst_stall > 0) {
    [NSThread sleepForTimeInterval:burst_stall];
  }
}

static void timing_tick(void);
static void timing_tick_impl(void) {
  if (finished) {
    return;
  }
  NSWindow *window = NSApp.keyWindow;
  NSView *view = terminal_view(window.contentView);
  const double now = CACurrentMediaTime();
  if (!started) {
    if (last_match && [NSFileManager.defaultManager fileExistsAtPath:settled_path]) {
      if (ready_path && !ready) {
        if (![[NSData data] writeToFile:ready_path atomically:YES]) {
          abort();
        }
        ready = YES;
      }
      if (release_path && ![NSFileManager.defaultManager fileExistsAtPath:release_path]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DriverTickNanoseconds), dispatch_get_main_queue(), ^{
          timing_tick();
        });
        return;
      }
      atomic_store(&commit_hook_ns, 0);
      atomic_store(&completion_hook_ns, 0);
      atomic_store(&copy_count, 0);
      atomic_store(&record_hook_ns, 0);
      atomic_store(&encoder_hook_ns, 0);
      atomic_store(&drawable_hook_ns, 0);
      atomic_store(&tick_hook_ns, 0);
      atomic_store(&measuring, true);
      started = YES;
      phase = 1;
      phase_started = now;
      select_query(view);
    }
  } else {
    if (!NSApp.isActive || !window.isKeyWindow || !NSEqualSizes(view.bounds.size, viewport)) {
      finish_timing(@"Native focus or geometry changed during query trial");
      return;
    }
    if (now - phase_started > QueryTimeoutSeconds) {
      finish_timing(phase == 1 ? @"Native select-all did not select the query" : earliest_presentation > 0 && atomic_load(&pending_submissions) > 0 ? @"Submitted drawables did not complete their pixel/presentation callbacks"
                                                                                                                                                    : @"No positively presented new result before timeout");
      return;
    }
    if (phase == 1) {
      NSString *before = input_text(view);
      NSRange selected = [(id<NSTextInputClient>)view selectedRange];
      if (selected.location == 0 && selected.length == before.length && before.length) {
        expected_query = [before isEqualToString:queries[0]] ? queries[1] : queries[0];
        earliest_presentation = 0;
        earliest_drawable = 0;
        latest_presentation = 0;
        latest_match = nil;
        phase_started = now;
        if (burst_interval > 0) {
          offer_burst(view);
        } else {
          phase = 2;
          input_time = CACurrentMediaTime();
          query_start_time = input_time;
          [(id<NSTextInputClient>)view insertText:expected_query replacementRange:NSMakeRange(NSNotFound, 0)];
          if (![input_text(view) isEqualToString:expected_query]) {
            finish_timing(@"Native query replacement did not produce the expected text");
            return;
          }
        }
      }
    } else if (phase == 2 && earliest_presentation > 0 && atomic_load(&pending_submissions) == 0 && now - earliest_presentation >= callback_drain && now - query_start_time >= minimum_query_interval) {
      if (![latest_match isEqualToString:expected_query]) {
        finish_timing(@"A stale result replaced the completed query");
        return;
      }
      [trials addObject:@{@"query" : expected_query,
                          @"burst_inputs" : burst_inputs ?: @[],
                          @"input_time" : @(input_time),
                          @"query_start_time" : @(query_start_time),
                          @"presented_time" : @(earliest_presentation),
                          @"last_presented_time" : @(latest_presentation),
                          @"last_match" : latest_match,
                          @"drawable_id" : @(earliest_drawable),
                          @"latency_ms" : @((earliest_presentation - input_time) * 1000)}];
      if (trials.count >= requested_trials) {
        finish_timing(zero_new ? @"New result had a zero presentation timestamp; first visible endpoint is ambiguous" : nil);
        return;
      }
      phase = 1;
      phase_started = now;
      select_query(view);
    }
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DriverTickNanoseconds), dispatch_get_main_queue(), ^{
    timing_tick();
  });
}

static void timing_tick(void) {
  const double began = CACurrentMediaTime();
  timing_tick_impl();
  add_probe_time(&tick_hook_ns, began);
}

static void record_frame_impl(HistoryFrame *frame) {
  if (frame.recorded || !frame.receivedPresentation || !frame.verified) {
    return;
  }
  if (timing && started && phase == 2 && !callback_suppressed && [negative_control isEqualToString:@"callback"] && frame.committedTime >= input_time) {
    callback_suppressed = YES;
    frame.receivedPresentation = NO;
    return;
  }
  frame.recorded = YES;
  if (!frame.submitted || atomic_fetch_sub(&pending_submissions, 1) == 0) {
    abort();
  }
  if (started && !finished && NSApp.keyWindow.screen.deviceDescription[@"NSScreenNumber"] == nil) {
    finish_timing(@"Native screen identity unavailable");
    return;
  }
  if (started && !finished) {
    measured_frames++;
    gpu_work_total += frame.gpuWork;
    gpu_work_max = MAX(gpu_work_max, frame.gpuWork);
  }
  if (diagnostic && started && !finished) {
    if (diagnostic_frames.count >= MaximumDiagnosticFrames) {
      abort();
    }
    [diagnostic_frames addObject:frame];
  }
  if (timing && started && phase == 2 && [negative_control isEqualToString:@"zero"]) {
    frame.presentedTime = 0;
  }
  if (frame.presentedTime <= 0) {
    zero_count++;
    if (timing && started && phase == 2) {
      ignored_zero++;
      if ([frame.matched isEqualToString:expected_query]) {
        zero_new++;
      }
    }
    return;
  }
  presented_count++;
  if (timing) {
    if (finished) {
      return;
    }
    if (frame.matched.length) {
      last_match = frame.matched;
    }
    if (started && phase == 2 && frame.presentedTime >= input_time) {
      if (frame.presentedTime >= latest_presentation) {
        latest_presentation = frame.presentedTime;
        latest_match = frame.matched;
      }
      NSView *view = terminal_view(NSApp.keyWindow.contentView);
      if (![input_text(view) isEqualToString:expected_query]) {
        finish_timing(@"Native input text changed before result presentation");
        return;
      }
      NSString *observed = [negative_control isEqualToString:@"stale"] ? ([expected_query isEqualToString:queries[0]] ? queries[1] : queries[0]) : frame.matched;
      if ([negative_control isEqualToString:@"missing"]) {
        observed = @"";
      }
      if ([observed isEqualToString:expected_query]) {
        if (!earliest_presentation || frame.presentedTime < earliest_presentation) {
          earliest_presentation = frame.presentedTime;
          earliest_drawable = frame.drawableID;
        }
        if ([negative_control isEqualToString:@"late-stale"]) {
          latest_match = @"";
          late_stale_injected = YES;
        }
      } else if (observed.length) {
        ignored_old++;
      }
    }
    return;
  }
  NSWindow *window = NSApp.keyWindow;
  NSView *view = terminal_view(window.contentView);
  NSDictionary *record = @{@"drawable_id" : @(frame.drawableID),
                           @"presented_time" : @(frame.presentedTime),
                           @"pixel_format" : @(frame.format),
                           @"matched" : frame.matched,
                           @"presented_count" : @(presented_count),
                           @"zero_count" : @(zero_count),
                           @"dropped_count" : @(dropped_count),
                           @"active" : @(NSApp.isActive),
                           @"key_window" : @(window.isKeyWindow),
                           @"view_points" : @[ @(view.bounds.size.width), @(view.bounds.size.height) ],
                           @"input_text" : view ? input_text(view) : @""};
  [observations addObject:record];
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"scope" : @"Same-submission native ROI qualification only; no query latency claim", @"frames" : observations} options:NSJSONWritingPrettyPrinted error:nil];
  if (![json writeToFile:destination atomically:YES]) {
    abort();
  }
}

static void record_frame(HistoryFrame *frame) {
  const double began = CACurrentMediaTime();
  record_frame_impl(frame);
  add_probe_time(&record_hook_ns, began);
}

static id encoder(id self, SEL selector, MTLRenderPassDescriptor *pass) {
  const double began = CACurrentMediaTime();
  id<MTLTexture> texture = pass.colorAttachments[0].texture;
  if (texture && objc_getAssociatedObject(texture, &frame_key)) {
    objc_setAssociatedObject(self, &command_texture_key, texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  add_probe_time(&encoder_hook_ns, began);
  return ((id (*)(id, SEL, id))original_encoder)(self, selector, pass);
}

static HistorySubmission *prepare_readback(id<MTLTexture> texture) {
  HistoryFrame *frame = texture ? objc_getAssociatedObject(texture, &frame_key) : nil;
  if (!frame) {
    return nil;
  }
  HistoryReadback *slot = nil;
  @synchronized(slots) {
    if (!slots.count) {
      for (NSUInteger index = 0; index < BufferCount; index++) {
        HistoryReadback *created = [HistoryReadback new];
        created.buffer = [texture.device newBufferWithLength:readback_pitch * RegionHeight options:MTLResourceStorageModeShared];
        if (!created.buffer) {
          abort();
        }
        [slots addObject:created];
      }
    }
    for (HistoryReadback *candidate in slots) {
      if (!candidate.busy) {
        candidate.busy = YES;
        slot = candidate;
        break;
      }
    }
  }
  if (!slot) {
    // Dropping a frame could hide the first result presentation. Fail closed.
    fprintf(stderr, "history observer: readback pool exhausted\n");
    abort();
  }
  @synchronized(frame) {
    if (frame.submitted) {
      // Multiple submissions for one drawable need a different completion join.
      abort();
    }
    frame.submitted = YES;
    atomic_fetch_add(&pending_submissions, 1);
  }
  HistorySubmission *submission = [HistorySubmission new];
  submission.frame = frame;
  submission.slot = slot;
  submission.texture = texture;
  return submission;
}

static void encode_readback(id copy, HistorySubmission *submission) {
  if (!copy) {
    abort();
  }
  const NSUInteger pitch = readback_pitch;
  [copy copyFromTexture:submission.texture
                   sourceSlice:0
                   sourceLevel:0
                  sourceOrigin:MTLOriginMake(RegionX, RegionY, 0)
                    sourceSize:MTLSizeMake(RegionWidth, RegionHeight, 1)
                      toBuffer:submission.slot.buffer
             destinationOffset:0
        destinationBytesPerRow:pitch
      destinationBytesPerImage:pitch * RegionHeight];
  [copy endEncoding];
  if (atomic_load(&measuring)) {
    atomic_fetch_add(&copy_count, 1);
  }
}

static BOOL matches_template(const void *bytes, NSData *expected) {
  const NSUInteger row_bytes = RegionWidth * PixelBytes;
  if (readback_pitch == row_bytes) {
    return memcmp(bytes, expected.bytes, row_bytes * RegionHeight) == 0;
  }

  for (NSUInteger row = 0; row < RegionHeight; row++) {
    if (memcmp((const uint8_t *)bytes + row * readback_pitch, (const uint8_t *)expected.bytes + row * row_bytes, row_bytes) != 0) {
      return NO;
    }
  }

  return YES;
}

static NSData *packed_pixels(const void *bytes) {
  const NSUInteger row_bytes = RegionWidth * PixelBytes;
  if (readback_pitch == row_bytes) {
    return [NSData dataWithBytes:bytes length:row_bytes * RegionHeight];
  }

  NSMutableData *packed = [NSMutableData dataWithLength:row_bytes * RegionHeight];
  for (NSUInteger row = 0; row < RegionHeight; row++) {
    memcpy((uint8_t *)packed.mutableBytes + row * row_bytes, (const uint8_t *)bytes + row * readback_pitch, row_bytes);
  }

  return packed;
}

static void complete_readback(HistorySubmission *submission, double gpu_work) {
  const double done = CACurrentMediaTime();
  HistoryReadback *slot = submission.slot;
  HistoryFrame *frame = submission.frame;
  const BOOL first = matches_template(slot.buffer.contents, templates[0]);
  const BOOL second = matches_template(slot.buffer.contents, templates[1]);
  NSData *pixels = diagnostic || (!timing && (first || second)) ? packed_pixels(slot.buffer.contents) : nil;
  NSData *raw = !timing && (first || second) ? pixels : nil;
  @synchronized(slots) {
    slot.busy = NO;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    frame.verified = YES;
    frame.completedTime = done;
    frame.gpuWork = gpu_work;
    frame.pixels = pixels;
    frame.matched = first ? queries[0] : second ? queries[1]
                                                : @"";
    if (raw) {
      NSString *path = [destination stringByAppendingFormat:@".%@.bgra", first ? @"first" : @"second"];
      if (![NSFileManager.defaultManager fileExistsAtPath:path] && ![raw writeToFile:path atomically:YES]) {
        abort();
      }
    }
    record_frame(frame);
  });
  add_probe_time(&completion_hook_ns, done);
}

static void commit(id<MTLCommandBuffer> command, SEL selector) {
  const double hook_started = CACurrentMediaTime();
  HistorySubmission *submission = prepare_readback(objc_getAssociatedObject(command, &command_texture_key));
  if (submission) {
    encode_readback([command blitCommandEncoder], submission);
    submission.frame.committedTime = CACurrentMediaTime();
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      if (completed.status != MTLCommandBufferStatusCompleted) {
        abort();
      }
      complete_readback(submission, completed.GPUEndTime - completed.GPUStartTime);
    }];
  }
  add_probe_time(&commit_hook_ns, hook_started);
  ((void (*)(id, SEL))original_commit)(command, selector);
}

static id encoder4(id self, SEL selector, MTL4RenderPassDescriptor *pass) {
  const double began = CACurrentMediaTime();
  objc_setAssociatedObject(self, &command_texture_key, pass.colorAttachments[0].texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  add_probe_time(&encoder_hook_ns, began);
  return ((id (*)(id, SEL, id))original_encoder4)(self, selector, pass);
}

static void end4(id<MTL4CommandBuffer> command, SEL selector) {
  const double began = CACurrentMediaTime();
  objc_setAssociatedObject(command, &readback_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  HistorySubmission *submission = prepare_readback(objc_getAssociatedObject(command, &command_texture_key));
  if (submission) {
    HistoryReadback *slot = submission.slot;
    if (!slot.residency) {
      MTLResidencySetDescriptor *descriptor = [MTLResidencySetDescriptor new];
      descriptor.initialCapacity = 2;
      slot.residency = [submission.texture.device newResidencySetWithDescriptor:descriptor error:nil];
      if (!slot.residency) {
        abort();
      }
      [slot.residency addAllocation:slot.buffer];
    }
    if (slot.residentTexture != submission.texture) {
      if (slot.residentTexture) {
        [slot.residency removeAllocation:slot.residentTexture];
      }
      [slot.residency addAllocation:submission.texture];
      slot.residentTexture = submission.texture;
      [slot.residency commit];
    }
    [command useResidencySet:slot.residency];
    id<MTL4ComputeCommandEncoder> copy = [command computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:0];
    encode_readback(copy, submission);
    objc_setAssociatedObject(command, &readback_key, submission, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  add_probe_time(&commit_hook_ns, began);
  ((void (*)(id, SEL))original_end4)(command, selector);
}

static void commit4(id self, SEL selector, const id<MTL4CommandBuffer> *buffers, NSUInteger count, MTL4CommitOptions *options) {
  const double began = CACurrentMediaTime();
  MTL4CommitOptions *actual = options ?: [MTL4CommitOptions new];
  for (NSUInteger index = 0; index < count; index++) {
    HistorySubmission *submission = objc_getAssociatedObject(buffers[index], &readback_key);
    if (submission) {
      submission.frame.committedTime = CACurrentMediaTime();
      [actual addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        if (feedback.error) {
          abort();
        }
        complete_readback(submission, feedback.GPUEndTime - feedback.GPUStartTime);
      }];
    }
  }
  add_probe_time(&commit_hook_ns, began);
  ((void (*)(id, SEL, const id<MTL4CommandBuffer> *, NSUInteger, id))original_commit4)(self, selector, buffers, count, actual);
}

static id backing_layer(id self, SEL selector) {
  CAMetalLayer *layer = ((id (*)(id, SEL))original_layer)(self, selector);
  layer.framebufferOnly = NO;
  return layer;
}

static id next_drawable(CAMetalLayer *layer, SEL selector) {
  layer.framebufferOnly = NO;
  id<CAMetalDrawable> drawable = ((id (*)(id, SEL))original_next)(layer, selector);
  const double began = CACurrentMediaTime();
  id<MTLTexture> texture = drawable.texture;
  if (texture.width == ProbeWidth && texture.height == ProbeHeight) {
    if (texture.pixelFormat != MTLPixelFormatBGRA8Unorm && texture.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) {
      abort();
    }
    if (!layer.displaySyncEnabled) {
      abort();
    }
    atomic_store(&display_sync, layer.displaySyncEnabled);
    atomic_store(&maximum_drawables, layer.maximumDrawableCount);
    HistoryFrame *frame = [HistoryFrame new];
    frame.drawableID = drawable.drawableID;
    frame.format = texture.pixelFormat;
    objc_setAssociatedObject(texture, &frame_key, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
      const double time = presented.presentedTime;
      dispatch_async(dispatch_get_main_queue(), ^{
        frame.receivedPresentation = YES;
        frame.presentedTime = time;
        record_frame(frame);
      });
    }];
  } else if (texture) {
    objc_setAssociatedObject(texture, &frame_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  add_probe_time(&drawable_hook_ns, began);
  return drawable;
}

__attribute__((constructor)) static void install(void) {
  const char *path = getenv("TELAR_HISTORY_OBSERVER");
  if (!path) {
    return;
  }
  @autoreleasepool {
    destination = @(path);
    timing = getenv("TELAR_HISTORY_TIMING") != NULL;
    diagnostic = getenv("TELAR_HISTORY_DIAGNOSTIC") != NULL;
    if (diagnostic) {
      diagnostic_frames = [NSMutableArray arrayWithCapacity:MaximumDiagnosticFrames];
    }
    if (timing) {
      settled_path = @(getenv("TELAR_HISTORY_SETTLED"));
      if (getenv("TELAR_HISTORY_READY")) {
        ready_path = @(getenv("TELAR_HISTORY_READY"));
      }
      if (getenv("TELAR_HISTORY_RELEASE")) {
        release_path = @(getenv("TELAR_HISTORY_RELEASE"));
      }
      requested_trials = (NSUInteger)strtoul(getenv("TELAR_HISTORY_TIMING"), NULL, 10);
      if (!requested_trials || requested_trials > 10000) {
        abort();
      }
      if (getenv("TELAR_HISTORY_NEGATIVE")) {
        negative_control = @(getenv("TELAR_HISTORY_NEGATIVE"));
      }
      trials = [NSMutableArray arrayWithCapacity:requested_trials];
    }
    const char *case_path = getenv("TELAR_HISTORY_CASE");
    if (!case_path) {
      abort();
    }
    NSData *case_bytes = [NSData dataWithContentsOfFile:@(case_path)];
    NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:case_bytes options:0 error:nil];
    NSArray *region = settings[@"region"], *drawable = settings[@"drawable"], *size = settings[@"viewport"], *entries = settings[@"queries"];
    if (region.count != 4 || drawable.count != 2 || size.count != 2 || entries.count != 2) {
      abort();
    }
    ProbeWidth = [drawable[0] unsignedIntegerValue];
    ProbeHeight = [drawable[1] unsignedIntegerValue];
    RegionX = [region[0] unsignedIntegerValue];
    RegionY = [region[1] unsignedIntegerValue];
    RegionWidth = [region[2] unsignedIntegerValue];
    RegionHeight = [region[3] unsignedIntegerValue];
    const NSUInteger RowPitchAlignment = 256;
    readback_pitch = ((RegionWidth * PixelBytes + RowPitchAlignment - 1) / RowPitchAlignment) * RowPitchAlignment;
    viewport = NSMakeSize([size[0] doubleValue], [size[1] doubleValue]);
    overall_timeout = [settings[@"timeout_seconds"] doubleValue];
    burst_interval = [settings[@"burst_interval_ms"] doubleValue] / 1000;
    burst_stall = [settings[@"burst_main_stall_ms"] doubleValue] / 1000;
    minimum_query_interval = [settings[@"minimum_query_interval_ms"] doubleValue] / 1000;
    if (settings[@"callback_drain_ms"]) {
      callback_drain = [settings[@"callback_drain_ms"] doubleValue] / 1000;
    }
    if (!ProbeWidth || !ProbeHeight || ProbeWidth > 8192 || ProbeHeight > 8192 ||
        !RegionWidth || !RegionHeight || RegionX > ProbeWidth || RegionY > ProbeHeight ||
        RegionWidth > ProbeWidth - RegionX || RegionHeight > ProbeHeight - RegionY ||
        RegionWidth * RegionHeight * PixelBytes > 1024 * 1024 ||
        !isfinite(overall_timeout) || overall_timeout < 5 || overall_timeout > 3600 ||
        !isfinite(viewport.width) || !isfinite(viewport.height) || viewport.width < 1 || viewport.height < 1 ||
        !isfinite(burst_interval) || burst_interval < 0 || burst_interval > .25 ||
        !isfinite(burst_stall) || burst_stall < 0 || burst_stall > .5 ||
        !isfinite(minimum_query_interval) || minimum_query_interval < 0 || minimum_query_interval > 1 ||
        !isfinite(callback_drain) || callback_drain < CallbackDrainSeconds || callback_drain > 1) {
      abort();
    }
    for (NSUInteger index = 0; index < 2; index++) {
      queries[index] = entries[index][@"text"];
      templates[index] = [NSData dataWithContentsOfFile:entries[index][@"template"]];
      if (!queries[index].length || queries[index].length > 128 || templates[index].length != RegionWidth * RegionHeight * PixelBytes) {
        abort();
      }
    }
    if ([queries[0] isEqualToString:queries[1]] || [templates[0] isEqualToData:templates[1]]) {
      abort();
    }
    observations = [NSMutableArray array];
    slots = [NSMutableArray arrayWithCapacity:BufferCount];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    Method encode_method = class_getInstanceMethod([command class], @selector(renderCommandEncoderWithDescriptor:));
    Method commit_method = class_getInstanceMethod([command class], @selector(commit));
    Method next = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (!encode_method || !commit_method || !next) {
      abort();
    }
    original_encoder = method_setImplementation(encode_method, (IMP)encoder);
    original_commit = method_setImplementation(commit_method, (IMP)commit);
    if (@available(macOS 26.0, *)) {
      if ([device supportsFamily:MTLGPUFamilyMetal4]) {
        id<MTL4CommandBuffer> command4 = [device newCommandBuffer];
        id<MTL4CommandQueue> queue4 = [device newMTL4CommandQueue];
        Method encode4 = class_getInstanceMethod([command4 class], @selector(renderCommandEncoderWithDescriptor:));
        Method end_method4 = class_getInstanceMethod([command4 class], @selector(endCommandBuffer));
        Method commit_method4 = class_getInstanceMethod([queue4 class], @selector(commit:count:options:));
        if (!encode4 || !end_method4 || !commit_method4) {
          abort();
        }
        original_encoder4 = method_setImplementation(encode4, (IMP)encoder4);
        original_end4 = method_setImplementation(end_method4, (IMP)end4);
        original_commit4 = method_setImplementation(commit_method4, (IMP)commit4);
        Class view = objc_getClass("TelarView");
        if (view) {
          original_layer = method_setImplementation(class_getInstanceMethod(view, @selector(makeBackingLayer)), (IMP)backing_layer);
        }
      }
    }
    original_next = method_setImplementation(next, (IMP)next_drawable);
    if (timing) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        timing_tick();
      });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(overall_timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        finish_timing(@"Observer qualification exceeded overall deadline");
      });
    }
  }
}
