#include "gui_view.h"
// Test-only common probe: one IOSurface pixel copied in the rendering command
// buffer, then verified at GPU completion. Works with CAMetalLayer and Ghostty
// 1.3 IOSurface targets. No presentation/scanout timestamps are inferred.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

static IMP original_next, original_encoder, original_commit;
static char texture_key, readback_key;
static IMP original_encoder4, original_end4, original_commit4, original_layer;
static FILE *probe_log;
static id<MTLCommandQueue> probe_queue;
static atomic_uint epoch;
static atomic_uint geometry_epoch;
static atomic_uintptr_t target_queue_identity;
static atomic_bool located;
static atomic_ulong marker_x, marker_y, pixel_width, pixel_height;
static BOOL pending, finished, text_input;
static int count, limit;
static double began, gpu_samples[512], gpu_work_samples[512];
static BOOL app_active_start[512], app_active_end[512], window_key_start[512], window_key_end[512];
static NSString *input_class;
static NSString *display_mode, *display_layout, *display_directory;
static NSView *primary_view;
static NSWindow *primary_window;
static id<MTLCommandQueue> target_queue;
typedef enum {
    ProbeSetupWaitFixture,
    ProbeSetupResize,
    ProbeSetupCreateLayout,
    ProbeSetupRestoreFocus,
    ProbeSetupLocateMarker,
    ProbeSetupResizeTabs,
    ProbeSetupForeground,
} ProbeSetupStage;

typedef enum {
    ProbeFixturesFailed = -1,
    ProbeFixturesWaiting,
    ProbeFixturesReady,
    ProbeFixturesAwaitingViewport,
} ProbeFixtureState;

typedef enum {
    ProbeFailureInputTimeout = 16,
    ProbeFailureForegroundLost = 17,
} ProbeFailureCode;

static ProbeSetupStage setup_stage = ProbeSetupWaitFixture;
static NSUInteger primary_geometry_generation, resize_fixture_generation;
static BOOL viewport_ack_required;
static BOOL foreground_requested, throughput_started;
static double foreground_stable_since, foreground_deadline;
static NSString *focus_failure_point;
static NSDictionary *focus_failure_frontmost;
static unsigned panes, created_panes, focus_steps, viewport_attempts;
static unsigned requested_width, requested_height;
static double setup_began, setup_changed, marker_located;
static BOOL setup_complete;
static BOOL awaiting_view_logged;
static BOOL activation_attempted;
static NSString *window_manager;
static NSTask *window_task;
static NSPipe *window_output;
static NSMutableArray<NSNumber *> *window_targets, *floated_window_ids;
static BOOL window_discovery, window_task_discovery;
static unsigned window_cycle_successes;
static double window_task_began, window_retry_after;
static BOOL window_floated;

@interface ProbeFrame : NSObject {
@public unsigned sequence; double gpu, work; BOOL verified;
}
@end
@implementation ProbeFrame
@end


static NSView *test_view(void) {
    if (primary_view) return primary_view;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        NSView *view = terminal_view(window.contentView);
        if (view) return view;
    }
    return nil;
}

static NSString *failure_message(int failed) {
    switch (failed) {
        case 0: return @"";
        case 2: return @"Primary native input view disappeared";
        case 3: return @"GPU completion preceded injected input";
        case 4: return @"Marker was not located after layout setup";
        case 5: return @"Benchmark timed out";
        case 6: return @"Render target geometry changed during measurement";
        case 7: return @"Input view does not support committed text";
        case 8: return @"Primary input view could not become first responder";
        case 9: return @"Invalid benchmark environment";
        case 10: return @"Layout setup or fixture readiness timed out";
        case 11: return @"Requested viewport could not be applied";
        case 12: return @"Fixture failed or unexpected fixture count";
        case 13: return @"GPU readback failed";
        case 14: return @"Primary tab is not visible after focus restoration";
        case 15: return @"Window manager command timed out";
        case ProbeFailureInputTimeout: return @"Input did not produce its expected marker within two seconds";
        case ProbeFailureForegroundLost: return @"Benchmark host was not active with its primary window key";
        default: return @"Unknown probe failure";
    }
}

static void collect_view_sizes(NSView *view, NSMutableArray *sizes) {
    if (!view) return;
    if (terminal_view(view) == view) {
        NSSize size = [view convertRectToBacking:view.bounds].size;
        [sizes addObject:@[@(size.width), @(size.height)]];
        return;
    }

    for (NSView *child in view.subviews) collect_view_sizes(child, sizes);
}

static void collect_view_frame(NSView *view, NSView *root, NSRect *bounds) {
    if (!view || view.isHiddenOrHasHiddenAncestor) return;
    if (terminal_view(view) == view) {
        NSRect frame = [root convertRectToBacking:[view convertRect:view.bounds toView:root]];
        *bounds = NSIsEmptyRect(*bounds) ? frame : NSUnionRect(*bounds, frame);
        return;
    }

    for (NSView *child in view.subviews) collect_view_frame(child, root, bounds);
}

static NSSize scene_size(void) {
    NSRect bounds = NSZeroRect;
    collect_view_frame(primary_window.contentView, primary_window.contentView, &bounds);
    return bounds.size;
}

static void finish(int failed) {
    if (finished) return;
    finished=YES;
    if (window_task.isRunning) kill(window_task.processIdentifier, SIGKILL);
    NSMutableArray *gpu = [NSMutableArray array], *work = [NSMutableArray array];
    NSMutableArray *active_start = [NSMutableArray array], *active_end = [NSMutableArray array];
    NSMutableArray *key_start = [NSMutableArray array], *key_end = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        [gpu addObject:@(gpu_samples[i])];
        [work addObject:@(gpu_work_samples[i])];
        [active_start addObject:@(app_active_start[i])];
        [active_end addObject:@(app_active_end[i])];
        [key_start addObject:@(window_key_start[i])];
        [key_end addObject:@(window_key_end[i])];
    }

    NSMutableArray *view_sizes = [NSMutableArray array];
    collect_view_sizes(primary_window.contentView, view_sizes);
    NSSize content_size = [primary_window.contentView convertRectToBacking:primary_window.contentView.bounds].size;
    NSSize view_size = [primary_view convertRectToBacking:primary_view.bounds].size;
    NSSize scene = scene_size();
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    NSDictionary *result = @{
        @"failed": @(failed), @"error": failure_message(failed),
        @"viewport": @[@(pixel_width), @(pixel_height)],
        @"requested_viewport": @[@(requested_width), @(requested_height)],
        @"window_content_pixels": @[@(content_size.width), @(content_size.height)],
        @"primary_view_pixels": @[@(view_size.width), @(view_size.height)],
        @"scene_pixels": @[@(scene.width), @(scene.height)],
        @"native_view_pixels": view_sizes,
        @"native_tab_count": @(primary_window.tabbedWindows.count ?: (primary_window ? 1 : 0)),
        @"marker": @[@(marker_x), @(marker_y)], @"gpu_ms": gpu, @"gpu_work_ms": work,
        @"app_active_start": active_start, @"app_active_end": active_end,
        @"window_key_start": key_start, @"window_key_end": key_end,
        @"foreground_required": @YES, @"focus_failure_point": focus_failure_point ?: @"",
        @"focus_failure_frontmost_application": focus_failure_frontmost ?: @{},
        @"input_class": input_class ?: @"", @"input_method": text_input ? @"text" : @"key",
        @"mode": display_mode ?: @"", @"layout": display_layout ?: @"single",
        @"panes_requested": @(panes), @"panes_created": @(created_panes),
        @"setup_complete": @(setup_complete),
        @"window_id": @(primary_window.windowNumber), @"window_floated": @(window_floated),
        @"floated_window_ids": floated_window_ids ?: @[],
        @"display_max_fps": @(primary_window.screen.maximumFramesPerSecond),
        @"backing_scale": @(primary_window.backingScaleFactor),
        @"host_user_cpu_seconds": @(usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6),
        @"host_system_cpu_seconds": @(usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6),
        @"host_max_rss_bytes": @(usage.ru_maxrss),
        @"target_filter": @"marker-qualified Metal command queue",
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    if (!json || ![json writeToFile:@(getenv("TELAR_DISPLAY_RESULT")) options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "probe could not write result: %s\n", error.description.UTF8String);
    }

    if (probe_log) fprintf(probe_log, "probe finished %d: %s\n", failed, failure_message(failed).UTF8String);
    [test_view().window close];
    // Ghostty can keep its app process alive after closing the only test window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
}

static BOOL require_foreground(NSString *point) {
    if (NSApp.isActive && primary_window.isKeyWindow) return YES;
    focus_failure_point = point;
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    focus_failure_frontmost = @{
        @"name": frontmost.localizedName ?: @"",
        @"pid": @(frontmost.processIdentifier),
        @"bundle_identifier": frontmost.bundleIdentifier ?: @"",
    };
    fprintf(probe_log, "probe foreground failure: point=%s completed=%d active=%d key_window=%d\n", point.UTF8String, count, NSApp.isActive, primary_window.isKeyWindow);
    fprintf(probe_log, "probe frontmost application: name=%s pid=%d bundle=%s\n", frontmost.localizedName.UTF8String ?: "", frontmost.processIdentifier, frontmost.bundleIdentifier.UTF8String ?: "");
    finish(ProbeFailureForegroundLost);
    return NO;
}

static BOOL prepare_foreground(void) {
    double now = CACurrentMediaTime();
    if (!foreground_requested) {
        foreground_requested = YES;
        foreground_stable_since = 0;
        foreground_deadline = now + 5;
        [NSApp activateIgnoringOtherApps:YES];
        [primary_window makeKeyAndOrderFront:nil];
        fprintf(probe_log, "probe requested foreground for primary window %ld\n", (long)primary_window.windowNumber);
    }

    if (NSApp.isActive && primary_window.isKeyWindow) {
        if (!foreground_stable_since) foreground_stable_since = now;
        return now - foreground_stable_since >= .5;
    }

    foreground_stable_since = 0;
    if (now > foreground_deadline) require_foreground(@"setup");
    return NO;
}

static void send_key(void) {
    if(finished)return;
    NSSize scene = scene_size();
    if (requested_width && (llround(scene.width) != requested_width || llround(scene.height) != requested_height)) { finish(11); return; }
    if(count==limit){finish(0);return;}
    if (!require_foreground(@"before_input")) return;
    NSView *view=test_view();
    NSWindow *w=view.window;
    if(!w){finish(2);return;}
    if(!w.isVisible){finish(14);return;}
    if (w.tabGroup && w.tabGroup.selectedWindow != w) { finish(14); return; }
    if(w.firstResponder != view && ![w makeFirstResponder:view]){finish(8);return;}
    NSResponder *target=text_input ? view : w.firstResponder;
    if(text_input && ![target respondsToSelector:@selector(insertText:replacementRange:)]){finish(7);return;}
    if(!count)input_class=NSStringFromClass(target.class);
    app_active_start[count] = NSApp.isActive;
    window_key_start[count] = w.isKeyWindow;
    pending=YES;
    atomic_store(&epoch,(unsigned)count+1);
    began=CACurrentMediaTime();
    if(text_input){
        [(id<NSTextInputClient>)target insertText:@"x" replacementRange:NSMakeRange(NSNotFound,0)];
    }else{
        [target keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7]];
    }
    unsigned sequence = (unsigned)count + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (finished || !pending || atomic_load(&epoch) != sequence) return;
        if (!require_foreground(@"input_watchdog")) return;
        fprintf(probe_log, "probe input timeout: completed=%d sequence=%u expected_color=%u marker=%lu,%lu viewport=%lux%lu active=%d key_window=%d first_responder=%s primary_tab_selected=%d\n", count, sequence, sequence & 1, marker_x, marker_y, pixel_width, pixel_height, NSApp.isActive, primary_window.isKeyWindow, NSStringFromClass(primary_window.firstResponder.class).UTF8String, !primary_window.tabGroup || primary_window.tabGroup.selectedWindow == primary_window);
        finish(ProbeFailureInputTimeout);
    });
}

typedef struct {
    NSString *characters, *unmodified;
    NSEventModifierFlags modifiers;
    unsigned short code;
} ProbeKey;

static BOOL inject_key(NSView *view, ProbeKey key) {
    NSWindow *window = view.window;
    if (!window || (window.firstResponder != view && ![window makeFirstResponder:view])) return NO;
    [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:key.modifiers timestamp:0 windowNumber:window.windowNumber context:nil
        characters:key.characters charactersIgnoringModifiers:key.unmodified isARepeat:NO keyCode:key.code]];
    return YES;
}

static NSView *active_view(void) {
    NSWindow *window = NSApp.keyWindow ?: primary_window;
    if ([window.firstResponder isKindOfClass:NSView.class]) {
        NSView *focused = (NSView *)window.firstResponder;
        if (terminal_view(focused) == focused) return focused;
    }
    return terminal_view(window.contentView);
}

static void reset_locator(void) {
    atomic_store_explicit(&located, false, memory_order_release);
    atomic_fetch_add(&geometry_epoch, 1);
    marker_located = 0;
}

static BOOL layout_key(BOOL create) {
    NSView *view = active_view();
    BOOL tabs = [display_layout isEqualToString:@"tabs"];
    if ([display_mode isEqualToString:@"ghostty"]) {
        ProbeKey key = { .modifiers = NSEventModifierFlagControl | NSEventModifierFlagShift };
        if (create && tabs) key.characters = @"\024", key.unmodified = @"T", key.code = 17;
        else if (create) key.characters = @"\004", key.unmodified = @"D", key.code = 2;
        else if (tabs) key.characters = @"\017", key.unmodified = @"O", key.code = 31;
        else key.characters = @"\020", key.unmodified = @"P", key.code = 35;
        return inject_key(view, key);
    }

    if (!inject_key(view, (ProbeKey){ @"\002", @"b", NSEventModifierFlagControl, 11 })) return NO;
    if (create && tabs) return inject_key(view, (ProbeKey){ @"c", @"c", 0, 8 });
    if (create) return inject_key(view, (ProbeKey){ @"%", @"%", NSEventModifierFlagShift, 23 });
    if (tabs) return inject_key(view, (ProbeKey){ @"p", @"p", 0, 35 });
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    return inject_key(view, (ProbeKey){ left, left, NSEventModifierFlagFunction, 123 });
}

static ProbeFixtureState fixtures_ready(unsigned expected) {
    if (!display_directory) return ProbeFixturesReady;
    NSString *directory = [display_directory stringByAppendingPathComponent:@"receipts"];
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
    unsigned total = 0, ready = 0, primary = 0;
    BOOL awaiting_viewport = NO;
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
        NSDictionary *receipt = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![receipt isKindOfClass:NSDictionary.class]) return ProbeFixturesFailed;
        total++;
        if ([receipt[@"role"] isEqualToString:@"primary"]) {
            primary++;
            primary_geometry_generation = [receipt[@"geometry_generation"] unsignedIntegerValue];
            awaiting_viewport = [receipt[@"phase"] isEqualToString:@"awaiting_viewport"];
        }
        if ([receipt[@"phase"] isEqualToString:@"ready"]) ready++;
        if ([receipt[@"phase"] isEqualToString:@"failed"] || [receipt[@"phase"] isEqualToString:@"finished"]) return ProbeFixturesFailed;
    }

    if (total > panes || primary > 1) return ProbeFixturesFailed;
    if (expected == 1 && total == 1 && primary == 1 && awaiting_viewport) return ProbeFixturesAwaitingViewport;
    return total == expected && ready == expected && primary == 1 ? ProbeFixturesReady : ProbeFixturesWaiting;
}

static BOOL control_window(void) {
    if (!window_manager || window_floated) return YES;
    if (window_task) {
        if (window_task.isRunning) {
            if (CACurrentMediaTime() - window_task_began > 3) {
                [window_task terminate];
                finish(15);
            }
            return NO;
        }
        if (window_task.terminationStatus == 0) {
            if (window_task_discovery) {
                NSData *data = [window_output.fileHandleForReading readDataToEndOfFile];
                NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                window_targets = [NSMutableArray array];
                for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                    long window_id = 0, pid = 0;
                    if (sscanf(line.UTF8String, "%ld %ld", &window_id, &pid) == 2 && pid == getpid() && window_id > 0) {
                        [window_targets addObject:@(window_id)];
                    }
                }
                window_discovery = window_targets.count == 0;
                if (window_discovery) window_retry_after = CACurrentMediaTime() + .25;
            } else {
                NSNumber *window_id = window_targets.firstObject;
                window_cycle_successes++;
                if (!floated_window_ids) floated_window_ids = [NSMutableArray array];
                if (![floated_window_ids containsObject:window_id]) [floated_window_ids addObject:window_id];
                fprintf(probe_log, "probe floated window %ld for process %d\n", window_id.longValue, getpid());
                [window_targets removeObjectAtIndex:0];
                if (!window_targets.count) {
                    window_floated = YES;
                    window_task = nil;
                    return YES;
                }
            }
        } else if (!window_task_discovery && window_cycle_successes && window_targets.count) {
            fprintf(probe_log, "probe skipping stale window %ld after %u successful floats in this setup cycle\n", window_targets.firstObject.longValue, window_cycle_successes);
            [window_targets removeObjectAtIndex:0];
            if (!window_targets.count) {
                window_floated = YES;
                window_task = nil;
                return YES;
            }
        } else {
            fprintf(probe_log, "probe window command failed with %d; discovering windows for process %d\n", window_task.terminationStatus, getpid());
            window_discovery = YES;
            window_retry_after = CACurrentMediaTime() + .25;
        }
        window_task = nil;
        window_output = nil;
    }

    if (CACurrentMediaTime() < window_retry_after) return NO;
    if (!window_targets) window_targets = [NSMutableArray arrayWithObject:@(primary_window.windowNumber)];
    window_task = [NSTask new];
    window_task.executableURL = [NSURL fileURLWithPath:window_manager];
    window_task_discovery = window_discovery;
    if (window_task_discovery) {
        window_task.arguments = @[@"list-windows", @"--all", @"--format", @"%{window-id} %{app-pid}"];
        window_output = [NSPipe pipe];
        window_task.standardOutput = window_output;
    } else {
        window_task.arguments = @[@"layout", @"--window-id", window_targets.firstObject.stringValue, @"floating"];
        window_task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    }
    window_task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![window_task launchAndReturnError:&error]) {
        fprintf(probe_log, "probe could not float window: %s\n", error.description.UTF8String);
        window_task = nil;
    }
    window_task_began = CACurrentMediaTime();
    return NO;
}

static BOOL resize_viewport(ProbeFixtureState fixtures) {
    NSSize size = [primary_view convertRectToBacking:primary_view.bounds].size;
    if (!requested_width || (llround(size.width) == requested_width && llround(size.height) == requested_height)) return YES;
    if (viewport_attempts++ == 4) { finish(11); return NO; }
    if (fixtures == ProbeFixturesAwaitingViewport) {
        resize_fixture_generation = primary_geometry_generation;
        viewport_ack_required = YES;
    }
    reset_locator();
    NSRect frame = primary_window.frame;
    CGFloat scale = primary_window.backingScaleFactor;
    frame.size.width += (requested_width - size.width) / scale;
    frame.size.height += (requested_height - size.height) / scale;
    [primary_window setFrame:frame display:YES];
    setup_changed = CACurrentMediaTime();
    return NO;
}

// Setup sends real native bindings, then waits for fixture receipts and a new
// marker readback. No setup key can become an input-latency sample.
static void setup_tick(void) {
    if (finished || setup_complete) return;
    double now = CACurrentMediaTime();
    if (now - setup_began > 35) { finish(setup_stage == ProbeSetupLocateMarker ? 4 : 10); return; }

    if (!primary_view) {
        primary_view = test_view();
        primary_window = primary_view.window;
        if (primary_view) created_panes = 1;
        if (!primary_view && !awaiting_view_logged && now - setup_began > 2) {
            awaiting_view_logged = YES;
            fprintf(probe_log, "probe awaiting view: active=%d hidden=%d windows=%lu delegate=%s\n", NSApp.isActive, NSApp.isHidden, NSApp.windows.count, NSStringFromClass(NSApp.delegate.class).UTF8String);
            for (NSWindow *window in NSApp.windows) {
                fprintf(probe_log, "probe window %ld: visible=%d class=%s content=%s terminal=%s\n", (long)window.windowNumber, window.isVisible, NSStringFromClass(window.class).UTF8String, NSStringFromClass(window.contentView.class).UTF8String, NSStringFromClass(terminal_view(window.contentView).class).UTF8String);
            }
        }
        if (!primary_view && !activation_attempted && now - setup_began > 2 && !NSApp.isActive && NSApp.delegate && ![display_mode isEqualToString:@"gui"]) {
            activation_attempted = YES;
            fprintf(probe_log, "probe activating instrumented host to request its initial window\n");
            [NSApp activateIgnoringOtherApps:YES];
        }
    }

    if (primary_view && now - setup_changed > .25 && control_window()) {
        ProbeFixtureState ready = fixtures_ready(created_panes);
        if (ready == ProbeFixturesFailed) { finish(12); return; }
        if (throughput_started) {
            if (!require_foreground(@"throughput")) return;
            if (ready == ProbeFixturesReady) throughput_started = NO;
        }
        if (setup_stage == ProbeSetupWaitFixture && (ready == ProbeFixturesReady || ready == ProbeFixturesAwaitingViewport)) {
            setup_stage = ProbeSetupResize;
        }

        if (setup_stage == ProbeSetupResize && prepare_foreground() && resize_viewport(ready)) {
            NSSize final_size = [primary_view convertRectToBacking:primary_view.bounds].size;
            // Readback stores its dimensions before publishing located. Acquire
            // them before releasing bulk output, so it uses pixel-only readback.
            BOOL marker_ready = atomic_load_explicit(&located, memory_order_acquire) &&
                pixel_width == llround(final_size.width) && pixel_height == llround(final_size.height);
            BOOL fixture_resized = !viewport_ack_required || primary_geometry_generation > resize_fixture_generation;
            if (ready != ProbeFixturesAwaitingViewport || (fixture_resized && marker_ready)) {
                if (ready == ProbeFixturesAwaitingViewport) {
                    NSString *path = [display_directory stringByAppendingPathComponent:@"viewport.ready"];
                    NSError *error = nil;
                    if (![[NSData data] writeToFile:path options:NSDataWritingAtomic error:&error]) {
                        fprintf(probe_log, "probe could not acknowledge viewport: %s\n", error.description.UTF8String);
                        finish(12);
                        return;
                    }
                    fprintf(probe_log, "probe acknowledged viewport at fixture geometry generation %lu\n", primary_geometry_generation);
                    throughput_started = YES;
                }
                setup_stage = ProbeSetupCreateLayout;
            }
        }

        if (setup_stage == ProbeSetupCreateLayout && ready == ProbeFixturesReady) {
            if (created_panes < panes) {
                reset_locator();
                if (!layout_key(YES)) { finish(8); return; }
                created_panes++;
                setup_changed = now;
                fprintf(probe_log, "probe requested %s %u/%u\n", display_layout.UTF8String, created_panes, panes);
            } else {
                setup_stage = ProbeSetupRestoreFocus;
                focus_steps = panes - 1;
                if ([display_mode isEqualToString:@"ghostty"] && [display_layout isEqualToString:@"tabs"]) focus_steps = 1;
            }
        }

        if (setup_stage == ProbeSetupRestoreFocus) {
            if (focus_steps || display_directory) reset_locator();
            if (focus_steps) {
                if (!layout_key(NO)) { finish(8); return; }
                focus_steps--;
                setup_changed = now;
            } else if (primary_window.tabGroup && primary_window.tabGroup.selectedWindow != primary_window) {
                primary_window.tabGroup.selectedWindow = primary_window;
                setup_changed = now;
                fprintf(probe_log, "probe selected the primary native tab before measurement\n");
            } else {
                if (!primary_window.isVisible) { finish(14); return; }
                setup_stage = ProbeSetupResizeTabs;
                setup_changed = now;
                if ([display_mode isEqualToString:@"ghostty"] && [display_layout isEqualToString:@"tabs"]) {
                    window_floated = NO;
                    window_task = nil;
                    window_targets = nil;
                    window_discovery = NO;
                    window_cycle_successes = 0;
                    viewport_attempts = 0;
                }
            }
        }

        if (setup_stage == ProbeSetupResizeTabs && control_window() && (![display_layout isEqualToString:@"tabs"] || resize_viewport(ready))) {
            foreground_requested = NO;
            setup_stage = ProbeSetupForeground;
        }

        if (setup_stage == ProbeSetupForeground && prepare_foreground()) {
            if (display_directory) reset_locator();
            setup_stage = ProbeSetupLocateMarker;
            setup_changed = now;
            if (display_directory && !inject_key(primary_view, (ProbeKey){ @"r", @"r", 0, 15 })) { finish(8); return; }
        }

        if (setup_stage == ProbeSetupLocateMarker && ready == ProbeFixturesReady && atomic_load_explicit(&located, memory_order_acquire) && now - marker_located > .35 && now - setup_began > 4) {
            setup_complete = YES;
            fprintf(probe_log, "probe setup complete: %s/%s, %u panes\n", display_mode.UTF8String, display_layout.UTF8String, panes);
            send_key();
            return;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ setup_tick(); });
}

static void accept_frame(ProbeFrame *frame) {
    if(!pending || frame->sequence!=(unsigned)count+1 || !frame->verified || !frame->gpu)return;
    if (!require_foreground(@"verified_frame")) return;
    gpu_samples[count]=(frame->gpu-began)*1000;
    if(gpu_samples[count]<0){finish(3);return;}
    gpu_work_samples[count] = frame->work;
    app_active_end[count] = NSApp.isActive;
    window_key_end[count] = primary_window.isKeyWindow;
    pending=NO;count++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(25+((uint32_t)(count*1103515245u+12345u)>>16)%50)*NSEC_PER_MSEC),dispatch_get_main_queue(),^{send_key();});
}

static int color(const uint8_t *p) {
    if(p[2]>160 && p[1]<80 && p[0]<120)return 0;
    if(p[1]>p[2]+60 && p[1]>160 && p[0]>120)return 1;
    return -1;
}

static id encoder(id self,SEL selector,MTLRenderPassDescriptor *pass){
    id<MTLTexture> texture=pass.colorAttachments[0].texture;
    if(texture.iosurface && (texture.pixelFormat==MTLPixelFormatBGRA8Unorm || texture.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB)){
        objc_setAssociatedObject(self,&texture_key,texture,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return ((id(*)(id,SEL,id))original_encoder)(self,selector,pass);
}

@interface ProbeReadback : NSObject {
@public ProbeFrame *frame;
    id<MTLTexture> texture;
    id<MTLBuffer> bytes;
    id<MTLResidencySet> residency;
    id<MTLCommandQueue> queue;
    BOOL known;
    unsigned geometry;
    NSUInteger x, y, width, height, pitch;
}
@end
@implementation ProbeReadback
@end

static ProbeReadback *prepare_readback(id<MTLTexture> texture, id<MTLCommandQueue> queue) {
    uintptr_t identity = atomic_load_explicit(&target_queue_identity, memory_order_acquire);
    if (identity && queue && identity != (uintptr_t)(__bridge void *)queue) return nil;
    if (!texture.width || !texture.height || texture.width > 8192 || texture.height > 8192) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(13); });
        return nil;
    }

    ProbeReadback *r = [ProbeReadback new];
    r->texture = texture;
    r->queue = queue;
    r->frame = [ProbeFrame new];
    r->frame->sequence = atomic_load(&epoch);
    r->geometry = atomic_load(&geometry_epoch);
    r->known = atomic_load_explicit(&located, memory_order_acquire) &&
        pixel_width == texture.width && pixel_height == texture.height;
    r->x = r->known ? marker_x : 0;
    r->y = r->known ? marker_y : 0;
    r->width = r->known ? 1 : texture.width;
    r->height = r->known ? 1 : texture.height;
    if (r->geometry != atomic_load(&geometry_epoch)) return nil;
    r->pitch = (r->width * 4 + 255) & ~255ul;
    r->bytes = [texture.device newBufferWithLength:r->pitch * r->height options:MTLResourceStorageModeShared];
    if (!r->bytes) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(13); });
        return nil;
    }
    return r;
}

static void verify_readback(ProbeReadback *r, double done) {
    if (r->geometry != atomic_load(&geometry_epoch)) return;
    if (r->frame->sequence && !r->known) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(6); });
        return;
    }
    const uint8_t *p = r->bytes.contents;
    if (!r->known) {
        NSUInteger sx = 0, sy = 0, n = 0;
        for (NSUInteger row = 0; row < r->height; row++) {
            for (NSUInteger col = 0; col < r->width; col++) {
                if (color(p + row * r->pitch + 4 * col) == 0) {
                    sx += col; sy += row; n++;
                }
            }
        }
        if (n) dispatch_async(dispatch_get_main_queue(), ^{
            if (r->geometry != atomic_load(&geometry_epoch) || finished) return;
            uintptr_t identity = atomic_load_explicit(&target_queue_identity, memory_order_acquire);
            if (identity && r->queue && identity != (uintptr_t)(__bridge void *)r->queue) return;
            BOOL previously_located = atomic_load_explicit(&located, memory_order_acquire);
            if (previously_located && pixel_width == r->texture.width && pixel_height == r->texture.height) return;
            if (primary_view) {
                NSSize current_size = [primary_view convertRectToBacking:primary_view.bounds].size;
                if (r->texture.width != llround(current_size.width) || r->texture.height != llround(current_size.height)) return;
            } else if (previously_located) {
                return;
            }
            if (previously_located) reset_locator();
            target_queue = r->queue;
            atomic_store_explicit(&target_queue_identity, (uintptr_t)(__bridge void *)target_queue, memory_order_release);
            marker_x = sx/n; marker_y = sy/n;
            pixel_width = r->texture.width; pixel_height = r->texture.height;
            marker_located = CACurrentMediaTime();
            atomic_store_explicit(&located, true, memory_order_release);
            fprintf(probe_log, "probe located %lu,%lu in %lux%lu\n", marker_x, marker_y, pixel_width, pixel_height);
        });
    } else {
        int value = color(p);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r->geometry != atomic_load(&geometry_epoch)) return;
            r->frame->gpu = done;
            r->frame->verified = value == (int)(r->frame->sequence & 1);
            accept_frame(r->frame);
        });
    }
}

// Both encoders expose this copy selector. Readback stays in the measured submission.
static void copy_pixel(id blit, ProbeReadback *r) {
    [blit copyFromTexture:r->texture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(r->x, r->y, 0) sourceSize:MTLSizeMake(r->width, r->height, 1)
        toBuffer:r->bytes destinationOffset:0 destinationBytesPerRow:r->pitch
        destinationBytesPerImage:r->pitch * r->height];
    [blit endEncoding];
}

static void commit(id self, SEL selector) {
    id<MTLTexture> texture = objc_getAssociatedObject(self, &texture_key);
    ProbeReadback *r = texture ? prepare_readback(texture, [(id<MTLCommandBuffer>)self commandQueue]) : nil;
    if (r) {
        copy_pixel([(id<MTLCommandBuffer>)self blitCommandEncoder], r);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            double done = CACurrentMediaTime();
            if (completed.status == MTLCommandBufferStatusCompleted) {
                r->frame->work = (completed.GPUEndTime - completed.GPUStartTime) * 1000;
                verify_readback(r, done);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ finish(13); });
            }
        }];
    }
    ((void(*)(id,SEL))original_commit)(self,selector);
}

static id encoder4(id self, SEL selector, MTL4RenderPassDescriptor *pass) {
    objc_setAssociatedObject(self, &texture_key, pass.colorAttachments[0].texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ((id(*)(id,SEL,id))original_encoder4)(self,selector,pass);
}

static void end4(id<MTL4CommandBuffer> self, SEL selector) {
    id<MTLTexture> texture = objc_getAssociatedObject(self, &texture_key);
    objc_setAssociatedObject(self, &readback_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ProbeReadback *r = texture ? prepare_readback(texture, nil) : nil;
    if (r) {
        MTLResidencySetDescriptor *desc = [MTLResidencySetDescriptor new];
        desc.initialCapacity = 2;
        r->residency = [texture.device newResidencySetWithDescriptor:desc error:nil];
        if (!r->residency) {
            dispatch_async(dispatch_get_main_queue(), ^{ finish(13); });
            ((void(*)(id,SEL))original_end4)(self,selector);
            return;
        }
        [r->residency addAllocation:texture];
        [r->residency addAllocation:r->bytes];
        [r->residency commit];
        [self useResidencySet:r->residency];
        id<MTL4ComputeCommandEncoder> blit = [self computeCommandEncoder];
        [blit barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:0];
        copy_pixel(blit, r);
        objc_setAssociatedObject(self, &readback_key, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void(*)(id,SEL))original_end4)(self,selector);
}

static void commit4(id self, SEL selector, const id<MTL4CommandBuffer> *buffers, NSUInteger count, MTL4CommitOptions *options) {
    for (NSUInteger i = 0; i < count; i++) {
        ProbeReadback *r = objc_getAssociatedObject(buffers[i], &readback_key);
        if (r) [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            double done = CACurrentMediaTime();
            if (!feedback.error) {
                r->frame->work = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000;
                verify_readback(r, done);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ finish(13); });
            }
        }];
    }
    ((void(*)(id,SEL,const id<MTL4CommandBuffer> *,NSUInteger,id))original_commit4)(self,selector,buffers,count,options);
}

static id backing_layer(id self, SEL selector) {
    CAMetalLayer *layer = ((id(*)(id,SEL))original_layer)(self,selector);
    layer.framebufferOnly = NO;
    return layer;
}

static id next_drawable(CAMetalLayer *self,SEL selector){
    self.framebufferOnly=NO;
    return ((id(*)(id,SEL))original_next)(self,selector);
}

__attribute__((constructor)) static void install(void){
    if(!getenv("TELAR_DISPLAY_RESULT"))return;
    // Runtime and fixture subprocesses inherit the environment; only GUI hosts instrument Metal.
    NSString *name=NSProcessInfo.processInfo.processName;
    if(![name isEqualToString:@"ghostty"] && ![NSProcessInfo.processInfo.arguments containsObject:@"gui"])return;
    const char *input_method=getenv("TELAR_DISPLAY_INPUT_METHOD");
    text_input=input_method && !strcmp(input_method,"text");
    if(text_input && ![NSProcessInfo.processInfo.arguments containsObject:@"gui"])abort();
    probe_log=fopen([[NSString stringWithUTF8String:getenv("TELAR_DISPLAY_RESULT")] stringByAppendingString:@".log"].UTF8String,"w");
    setbuf(probe_log,NULL);
    limit=atoi(getenv("TELAR_DISPLAY_SAMPLES"));if(limit<1 || limit>512)abort();
    const char *mode = getenv("TELAR_DISPLAY_MODE"), *layout = getenv("TELAR_DISPLAY_LAYOUT");
    display_mode = mode ? @(mode) : ([NSProcessInfo.processInfo.arguments containsObject:@"gui"] ? @"gui" : @"tui");
    display_layout = layout ? @(layout) : @"single";
    const char *directory = getenv("TELAR_DISPLAY_DIRECTORY");
    display_directory = directory ? @(directory) : nil;
    const char *manager = getenv("TELAR_DISPLAY_AEROSPACE");
    window_manager = manager ? @(manager) : nil;
    const char *pane_count = getenv("TELAR_DISPLAY_PANES");
    panes = [display_layout isEqualToString:@"single"] ? 1 : (pane_count ? (unsigned)atoi(pane_count) : 4);
    BOOL valid = [@[@"gui", @"tui", @"ghostty"] containsObject:display_mode] &&
        [@[@"single", @"splits", @"tabs"] containsObject:display_layout] && panes >= 1 && panes <= 8;
    const char *viewport = getenv("TELAR_DISPLAY_VIEWPORT");
    if (viewport) {
        char trailing;
        valid = valid && sscanf(viewport, "%u,%u%c", &requested_width, &requested_height, &trailing) == 2 &&
            requested_width >= 1 && requested_height >= 1 && requested_width <= 8192 && requested_height <= 8192;
    }
    if (!valid) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(9); });
        return;
    }
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();probe_queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[probe_queue commandBuffer];
    original_encoder=method_setImplementation(class_getInstanceMethod([command class],@selector(renderCommandEncoderWithDescriptor:)),(IMP)encoder);
    original_commit=method_setImplementation(class_getInstanceMethod([command class],@selector(commit)),(IMP)commit);
    if (@available(macOS 26.0, *)) {
        if ([device supportsFamily:MTLGPUFamilyMetal4]) {
            id<MTL4CommandBuffer> c4 = [device newCommandBuffer];
            id<MTL4CommandQueue> q4 = [device newMTL4CommandQueue];
            original_encoder4 = method_setImplementation(class_getInstanceMethod([c4 class], @selector(renderCommandEncoderWithDescriptor:)), (IMP)encoder4);
            original_end4 = method_setImplementation(class_getInstanceMethod([c4 class], @selector(endCommandBuffer)), (IMP)end4);
            original_commit4 = method_setImplementation(class_getInstanceMethod([q4 class], @selector(commit:count:options:)), (IMP)commit4);
            Class view = objc_getClass("TelarView");
            if (view) original_layer = method_setImplementation(class_getInstanceMethod(view, @selector(makeBackingLayer)), (IMP)backing_layer);
        }
    }
    original_next=method_setImplementation(class_getInstanceMethod(CAMetalLayer.class,@selector(nextDrawable)),(IMP)next_drawable);
    setup_began = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ setup_tick(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(5);});
}
