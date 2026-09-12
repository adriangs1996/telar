#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>

// One copied value crosses threads. AppKit objects stay on the main thread.
static _Atomic int32_t latest_value;
static _Atomic bool finished;
static int input_pipe[2] = {-1, -1};
static NSWindow *window;
static NSTimer *timer;
static bool input_failed;

@interface ExperView : NSView <NSWindowDelegate>
@property(nonatomic) int32_t value;
@end

@implementation ExperView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)sendByte:(char)byte {
    if (input_pipe[1] < 0) return;
    // Required-input saturation fails the input stream explicitly via EOF.
    if (write(input_pipe[1], &byte, 1) != 1) input_failed = true;
    if (input_failed || byte == 'q') {
        close(input_pipe[1]);
        input_pipe[1] = -1;
    }
}
- (void)keyDown:(NSEvent *)event {
    NSString *text = event.characters;
    if (text.length != 1) return;
    unichar key = [text characterAtIndex:0];
    if (key == '+' || key == '-' || key == 'q' || key == 3) {
        [self sendByte:key == 3 ? 'q' : (char)key];
    }
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    [self sendByte:'q'];
    return NO;
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:16 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    [@"Frontend experiment | q: quit | + / -: request"
        drawAtPoint:NSMakePoint(16, 16) withAttributes:attributes];
    NSRect outer = NSMakeRect(16, 52, self.bounds.size.width - 32, self.bounds.size.height - 68);
    [[NSColor separatorColor] setStroke];
    [[NSBezierPath bezierPathWithRect:outer] stroke];
    [@"Counter" drawAtPoint:NSMakePoint(outer.origin.x + 12, outer.origin.y + 8) withAttributes:attributes];
    NSRect inner = NSMakeRect(NSMidX(outer) - 110, NSMidY(outer) - 48, 220, 96);
    [[NSBezierPath bezierPathWithRect:inner] stroke];
    NSString *text = [NSString stringWithFormat:@"Value: %d", self.value];
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint(NSMidX(inner) - size.width / 2, NSMidY(inner) - size.height / 2)
        withAttributes:attributes];
}
@end

int exper_native_open(void) {
    @autoreleasepool {
        if (pipe(input_pipe) != 0) return -1;
        if (fcntl(input_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
            close(input_pipe[0]);
            close(input_pipe[1]);
            input_pipe[0] = input_pipe[1] = -1;
            return -1;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Telar frontend experiment";
        window.minSize = NSMakeSize(520, 260);
        window.releasedWhenClosed = NO;
        ExperView *view = [[ExperView alloc] initWithFrame:window.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        window.contentView = view;
        window.delegate = view;
        [window makeFirstResponder:view];
        [window center];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        // Simulation-only frame opportunities, matching the experiment's ticker.
        // At most one value is retained; a stalled host never queues frames.
        timer = [NSTimer timerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *unused) {
            if (atomic_load(&finished)) {
                [NSApp stop:nil];
                return;
            }
            int32_t value = atomic_load(&latest_value);
            if (view.value != value) {
                view.value = value;
                view.needsDisplay = YES;
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        return input_pipe[0];
    }
}

void exper_native_present(int32_t value) { atomic_store(&latest_value, value); }
void exper_native_stop(void) { atomic_store(&finished, true); }
int exper_native_run(void) {
    @autoreleasepool { [NSApp run]; }
    return input_failed ? -1 : 0;
}
void exper_native_close(void) {
    @autoreleasepool {
        [timer invalidate];
        timer = nil;
        [window close];
        window = nil;
        if (input_pipe[0] >= 0) close(input_pipe[0]);
        if (input_pipe[1] >= 0) close(input_pipe[1]);
        input_pipe[0] = input_pipe[1] = -1;
    }
}
