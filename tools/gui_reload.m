#include "gui_view.h"
// Test-only watcher exercise through real AppKit input, GPU frames and a PTY.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../src/gui/native/telar_gui.h"

static telar_gui_callbacks original;
static IMP original_init;
static void *app_context;
static float background[4];
static uint32_t atlas_version, previous_atlas;
static uint32_t background_blur;
static unsigned int stage, changed_frames;
static CFAbsoluteTime deadline, rejected_at;
static NSTimer *timer;

static void send_command(NSString *command) {
    NSWindow *window = NSApp.windows.firstObject;
    NSView *view = terminal_view(window.contentView);
    [(id<NSTextInputClient>)view insertText:command replacementRange:NSMakeRange(NSNotFound, 0)];
    [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
        characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
}

static void finish(BOOL failed) {
    [timer invalidate];
    NSDictionary *result = @{ @"failed": @(failed), @"stage": @(stage), @"appearance_frames": @(changed_frames) };
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:@"reload.json" atomically:YES];
    const char *capture = getenv("TELAR_GUI_CAPTURE");
    if (capture != NULL) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)NSApp.windows.firstObject.windowNumber], [NSString stringWithUTF8String:capture]];
        [task launchAndReturnError:nil];
        [task waitUntilExit];
    }
    [NSApp.windows.firstObject close];
}

static BOOL write_config(NSString *source) {
    NSError *error = nil;
    BOOL written = [source writeToFile:[NSString stringWithUTF8String:getenv("TELAR_GUI_RELOAD_CONFIG")]
                           atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!written) finish(YES);
    return written;
}

static BOOL color_is(unsigned int rgb) {
    return fabsf(background[0] - ((rgb >> 16) & 255) / 255.0f) < 0.001f &&
           fabsf(background[1] - ((rgb >> 8) & 255) / 255.0f) < 0.001f &&
           fabsf(background[2] - (rgb & 255) / 255.0f) < 0.001f;
}

static BOOL window_is(BOOL opaque, BOOL blurred) {
    NSWindow *window = NSApp.windows.firstObject;
    NSView *terminal = terminal_view(window.contentView);
    NSVisualEffectView *effect = (NSVisualEffectView *)window.contentView.subviews.firstObject;
    return window.isOpaque == opaque && terminal.layer.isOpaque == opaque &&
           [effect isKindOfClass:NSVisualEffectView.class] && effect.isHidden != blurred;
}

static void tick(void) {
    if (CFAbsoluteTimeGetCurrent() > deadline) { finish(YES); return; }
    NSFileManager *files = NSFileManager.defaultManager;
    switch (stage) {
    case 0:
        send_command(@"echo $$ > child.pid; stty size > before; printf input-ok > typed");
        stage = 1;
        break;
    case 1:
        if (![files fileExistsAtPath:@"before"]) return;
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'catppuccin', gui = { font = { family = 'Menlo', size = 22, line_height = 1.2 }, cursor = { style = 'bar', blink = true, blink_interval_ms = 250 } } }")) stage = 2;
        break;
    case 2:
        if (!color_is(0x1e1e2e) || atlas_version <= previous_atlas || original.wakeup_after(app_context) == 0) return;
        changed_frames++;
        send_command(@"stty size > font-size; printf '\\033[2J\\033[HHot reload: Menlo 22\\n' ");
        stage = 3;
        break;
    case 3:
        if (![files fileExistsAtPath:@"font-size"]) return;
        // Valid Lua with an unavailable font must reject the theme too.
        if (write_config(@"return { api_version = 2, theme = { terminal = { background = '#ff0000' } }, gui = { font = { family = 'Telar-Test-Missing-Family-98a34b1' } } }")) {
            rejected_at = CFAbsoluteTimeGetCurrent();
            stage = 4;
        }
        break;
    case 4:
        if (CFAbsoluteTimeGetCurrent() - rejected_at < 2.5) return;
        if (!color_is(0x1e1e2e)) { finish(YES); return; }
        send_command(@"stty size > invalid-size; printf 'Input after rejected reload\\n'");
        stage = 5;
        break;
    case 5:
        if (![files fileExistsAtPath:@"invalid-size"]) return;
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { style = 'block', blink = false } } }")) stage = 6;
        break;
    case 6:
        if (!color_is(0x1a1b26) || atlas_version <= previous_atlas || original.wakeup_after(app_context) != 0) return;
        changed_frames++;
        send_command(@"stty size > after; echo $$ > after.pid; printf 'Hot reload recovered; same shell\\n'");
        stage = 7;
        break;
    case 7:
        if (![files fileExistsAtPath:@"after.pid"]) return;
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { background_opacity = 0.5, background_blur = true, padding = { x = 16, y = 12 } } } }")) stage = 8;
        break;
    case 8:
        if (background[3] != .5f || !background_blur || !window_is(NO, YES)) return;
        if (atlas_version != previous_atlas) { finish(YES); return; }
        changed_frames++;
        send_command(@"stty size > padded-size");
        stage = 9;
        break;
    case 9:
        if (![files fileExistsAtPath:@"padded-size"]) return;
        if ([[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"padded-size"]]) { finish(YES); return; }
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false } } }")) stage = 10;
        break;
    case 10:
        if (background[3] != 1 || background_blur || !window_is(YES, NO)) return;
        if (atlas_version != previous_atlas) { finish(YES); return; }
        changed_frames++;
        send_command(@"stty size > unpadded-size");
        stage = 11;
        break;
    case 11:
        if (![files fileExistsAtPath:@"unpadded-size"]) return;
        if (![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"unpadded-size"]]) { finish(YES); return; }
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17, thicken = true, thicken_strength = 0 }, cursor = { blink = true } } }")) stage = 12;
        break;
    case 12:
        if (atlas_version <= previous_atlas || original.wakeup_after(app_context) == 0) return;
        changed_frames++;
        send_command(@"stty size > thicken-light-size");
        stage = 13;
        break;
    case 13:
        if (![files fileExistsAtPath:@"thicken-light-size"]) return;
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17, thicken = true, thicken_strength = 255 }, cursor = { blink = false } } }")) stage = 14;
        break;
    case 14:
        if (atlas_version <= previous_atlas || original.wakeup_after(app_context) != 0) return;
        changed_frames++;
        send_command(@"stty size > thicken-full-size");
        stage = 15;
        break;
    case 15:
        if (![files fileExistsAtPath:@"thicken-full-size"]) return;
        previous_atlas = atlas_version;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17, thicken = false }, cursor = { blink = true } } }")) stage = 16;
        break;
    case 16:
        if (atlas_version <= previous_atlas || original.wakeup_after(app_context) == 0) return;
        changed_frames++;
        send_command(@"stty size > thicken-off-size");
        stage = 17;
        break;
    case 17:
        if (![files fileExistsAtPath:@"thicken-off-size"]) return;
        finish(![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-light-size"]] ||
               ![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-full-size"]] ||
               ![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-off-size"]]);
        break;
    }
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    original.render(context, viewport, frame);
    memcpy(background, frame->background, sizeof(background));
    atlas_version = frame->atlas_version;
    background_blur = frame->background_blur;
}

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    app_context = context;
    original = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
}

__attribute__((constructor)) static void install(void) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;
    Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
    if (!method) abort();
    original_init = method_setImplementation(method, (IMP)initialize);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
        deadline = CFAbsoluteTimeGetCurrent() + 25;
        timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *unused) { tick(); }];
    });
}
