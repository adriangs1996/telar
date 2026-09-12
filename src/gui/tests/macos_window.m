#import <AppKit/AppKit.h>
#include "telar_gui.h"
#include <stdio.h>
#include <string.h>

static int paints, delivered, inputs, failed;
static const uint8_t pixels[] = {255,255,255,255};
static const telar_gui_quad quad = {20,20,200,100,0,0,1,1,0,1,0,1};
static void render(void *context, telar_gui_viewport viewport, telar_gui_frame *frame) {
    (void)context;
    if (!viewport.width || !viewport.height) failed++;
    *frame = (telar_gui_frame){.token = ++paints, .quads = &quad, .quad_count = 1, .atlas = pixels, .atlas_side = 2, .atlas_version = 1, .background = {0,0,0,1}};
}
static int pump(void *context) { (void)context; return 0; }
static void complete(void *context, uint64_t token, int success) { (void)context; if (token && success) delivered++; else failed++; }
static int input(void *context, telar_gui_input event) {
    (void)context;
    if (inputs == 0 && !(event.kind == 1 && event.len == 1 && event.text[0] == 'a')) failed++;
    if (inputs == 1 && !(event.kind == 4 && event.code == 'c' && (event.mods & 4))) failed++;
    if (inputs == 2 && !(event.kind == 3 && event.code == 1)) failed++;
    if (inputs == 3 && !(event.kind == 1 && event.len == 5 && !memcmp(event.text,"caf\xc3\xa9",5))) failed++;
    inputs++;
    return 1;
}
int main(void) {
    @autoreleasepool {
        int fds[2];
        if (telar_gui_pipe(fds)) return 2;
        telar_gui_callbacks callbacks = {render,pump,complete,input,fds[0]};
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000000000), dispatch_get_main_queue(), ^{
            NSWindow *window = NSApp.keyWindow;
            NSView *view = window.contentView;
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagControl timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\003" charactersIgnoringModifiers:@"c" isARepeat:NO keyCode:8]];
            [view keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
            [(id<NSTextInputClient>)view insertText:@"café" replacementRange:NSMakeRange(NSNotFound,0)];
            [window close];
        });
        int status = telar_gui_run("Telar native backend test", NULL, &callbacks);
        telar_gui_close_pipe(fds);
        fprintf(stdout, "native macOS: status=%d painted=%d delivered=%d inputs=%d failures=%d\n",status,paints,delivered,inputs,failed);
        return status || !delivered || inputs != 4 || failed;
    }
}
