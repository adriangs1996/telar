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
static telar_gui_frame pending_frame;
static IMP original_init;
static void *app_context;
static float background[4];
static uint32_t atlas_version, previous_atlas;
static const uint8_t *atlas_pixels, *previous_atlas_pixels;
static uint32_t background_blur;
static uint32_t titlebar;
static NSRect decorated_frame;
static unsigned int stage, changed_frames;
static CFAbsoluteTime deadline, rejected_at;
static NSTimer *timer;

@protocol TelarBackgroundProbe
@property(nonatomic, readonly) uint32_t appliedBlurRadius;
@end

static void send_command(NSString *command) {
    NSWindow *window = NSApp.windows.firstObject;
    NSView *view = terminal_view(window.contentView);
    [(id<NSTextInputClient>)view insertText:command replacementRange:NSMakeRange(NSNotFound, 0)];
    [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil
        characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
}

static void capture_window(NSString *suffix) {
    const char *capture = getenv("TELAR_GUI_CAPTURE");
    if (capture != NULL) {
        NSString *path = [NSString stringWithUTF8String:capture];
        if (suffix != nil) path = [[path stringByDeletingPathExtension] stringByAppendingFormat:@"-%@.png", suffix];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)NSApp.windows.firstObject.windowNumber], path];
        [task launchAndReturnError:nil];
        [task waitUntilExit];
    }
}

static void finish(BOOL failed) {
    [timer invalidate];
    NSDictionary *result = @{ @"failed": @(failed), @"stage": @(stage), @"appearance_frames": @(changed_frames),
        @"atlas_version": @(atlas_version), @"previous_atlas": @(previous_atlas),
        @"same_atlas": @(atlas_pixels == previous_atlas_pixels),
        @"opacity": @(background[3]), @"blur": @(background_blur),
        @"window_frame": NSStringFromRect(NSApp.windows.firstObject.frame),
        @"decorated_frame": NSStringFromRect(decorated_frame),
        @"applied_blur": @([(id<TelarBackgroundProbe>)NSApp.windows.firstObject.contentView appliedBlurRadius]) };
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:@"reload.json" atomically:YES];
    capture_window(nil);
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
    id<TelarBackgroundProbe> effect = (id<TelarBackgroundProbe>)window.contentView;
    return window.isOpaque == opaque && terminal.layer.isOpaque == opaque &&
           (effect.appliedBlurRadius != 0) == blurred;
}

static BOOL titlebar_is(BOOL visible) {
    NSWindow *window = NSApp.windows.firstObject;
    BOOL full_content = (window.styleMask & NSWindowStyleMaskFullSizeContentView) != 0;
    return titlebar == visible && full_content != visible &&
           window.titleVisibility == (visible ? NSWindowTitleVisible : NSWindowTitleHidden) &&
           [window standardWindowButton:NSWindowCloseButton].hidden != visible &&
           window.keyWindow && window.firstResponder == terminal_view(window.contentView);
}

static BOOL blur_is(uint32_t radius) {
    id<TelarBackgroundProbe> effect = (id<TelarBackgroundProbe>)NSApp.windows.firstObject.contentView;
    return background_blur == radius && effect.appliedBlurRadius == radius;
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
        previous_atlas_pixels = atlas_pixels;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { background_opacity = 0.5, background_blur = 20, padding = { x = 16, y = 12 } } } }")) stage = 8;
        break;
    case 8:
        if (background[3] != .5f || !background_blur || !window_is(NO, YES)) return;
        if (atlas_pixels != previous_atlas_pixels) { finish(YES); return; }
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
        if (atlas_pixels != previous_atlas_pixels) { finish(YES); return; }
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
        if (![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-light-size"]] ||
               ![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-full-size"]] ||
               ![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"thicken-off-size"]]) { finish(YES); return; }
        // Chrome can add new glyphs as metrics change. Page identity, rather
        // than upload version, proves a window-only reload retained the atlas.
        previous_atlas_pixels = atlas_pixels;
        decorated_frame = NSApp.windows.firstObject.frame;
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { titlebar = false, background_opacity = 0.5, background_blur = 40 } } }")) stage = 18;
        break;
    case 18:
        if (!titlebar_is(NO) || !blur_is(40)) return;
        if (atlas_pixels != previous_atlas_pixels || !NSEqualRects(decorated_frame, NSApp.windows.firstObject.frame)) { finish(YES); return; }
        changed_frames++;
        send_command(@"stty size > hidden-titlebar-size; printf 'Input with hidden titlebar\\n'");
        stage = 19;
        break;
    case 19:
        if (![files fileExistsAtPath:@"hidden-titlebar-size"]) return;
        capture_window(@"hidden-blur40");
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { titlebar = false, background_opacity = 0.5, background_blur = 80 } } }")) stage = 20;
        break;
    case 20:
        if (!titlebar_is(NO) || !blur_is(80)) return;
        if (atlas_pixels != previous_atlas_pixels) { finish(YES); return; }
        changed_frames++;
        send_command(@"stty size > stronger-blur-size");
        stage = 21;
        break;
    case 21:
        if (![files fileExistsAtPath:@"stronger-blur-size"]) return;
        if (![[files contentsAtPath:@"hidden-titlebar-size"] isEqualToData:[files contentsAtPath:@"stronger-blur-size"]]) { finish(YES); return; }
        capture_window(@"hidden-blur80");
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { titlebar = true, background_opacity = 0.5, background_blur = 80 } } }")) stage = 22;
        break;
    case 22:
        if (!titlebar_is(YES) || !blur_is(80)) return;
        if (atlas_pixels != previous_atlas_pixels || !NSEqualRects(decorated_frame, NSApp.windows.firstObject.frame)) { finish(YES); return; }
        changed_frames++;
        send_command(@"stty size > restored-titlebar-size");
        stage = 23;
        break;
    case 23:
        if (![files fileExistsAtPath:@"restored-titlebar-size"]) return;
        if (![[files contentsAtPath:@"after"] isEqualToData:[files contentsAtPath:@"restored-titlebar-size"]]) { finish(YES); return; }
        if (write_config(@"return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { titlebar = true, background_opacity = 0.5, background_blur = 0 } } }")) stage = 24;
        break;
    case 24:
        if (!titlebar_is(YES) || !blur_is(0) || !window_is(NO, NO)) return;
        if (atlas_pixels != previous_atlas_pixels) { finish(YES); return; }
        changed_frames++;
        finish(NO);
        break;
    }
}

static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    original.render(context, viewport, frame);
    if (frame->token == 0) return;
    pending_frame = *frame;
}

static void complete(void *context, uint64_t token, int delivered) {
    // A titlebar change can discard a preparation with the previous viewport.
    // Observe only the native submission that actually completed successfully.
    if (delivered && token == pending_frame.token) {
        atlas_pixels = pending_frame.atlas;
        memcpy(background, pending_frame.background, sizeof(background));
        atlas_version = pending_frame.atlas_version;
        background_blur = pending_frame.background_blur;
        titlebar = pending_frame.titlebar;
    }
    original.complete(context, token, delivered);
}

static id initialize(id self, SEL selector, NSRect frame, void *context, const telar_gui_callbacks *callbacks) {
    app_context = context;
    original = *callbacks;
    telar_gui_callbacks wrapped = *callbacks;
    wrapped.render = render;
    wrapped.complete = complete;
    return ((id (*)(id, SEL, NSRect, void *, const telar_gui_callbacks *))original_init)(self, selector, frame, context, &wrapped);
}

__attribute__((constructor)) static void install(void) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"gui"]) return;
    Method method = class_getInstanceMethod(objc_getClass("TelarView"), sel_registerName("initWithFrame:context:callbacks:"));
    if (!method) abort();
    original_init = method_setImplementation(method, (IMP)initialize);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2), dispatch_get_main_queue(), ^{
        deadline = CFAbsoluteTimeGetCurrent() + 40;
        timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *unused) { tick(); }];
    });
}
