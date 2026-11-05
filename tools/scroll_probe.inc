@interface ScrollLatencyEvent : NSEvent
@property(nonatomic, weak) NSWindow *target;
@property(nonatomic) NSPoint point;
@end

@implementation ScrollLatencyEvent
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (NSWindow *)window { return self.target; }
- (NSInteger)windowNumber { return self.target.windowNumber; }
- (NSPoint)locationInWindow { return self.point; }
- (CGFloat)scrollingDeltaX { return 0; }
- (CGFloat)scrollingDeltaY { return 1; }
- (CGFloat)deltaX { return 0; }
- (CGFloat)deltaY { return 1; }
- (BOOL)hasPreciseScrollingDeltas { return NO; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSEventModifierFlags)modifierFlags { return 0; }
- (NSEventPhase)phase { return NSEventPhaseNone; }
- (NSEventPhase)momentumPhase { return NSEventPhaseNone; }
- (NSTimeInterval)timestamp { return NSProcessInfo.processInfo.systemUptime; }
- (NSUInteger)deviceID { return 0; }
@end

static unsigned scroll_top_row;
static unsigned scroll_expected[ProbeSampleCapacity], scroll_observed[ProbeSampleCapacity];
static double scroll_input_at[ProbeSampleCapacity], scroll_presented_at[ProbeSampleCapacity];
static atomic_ulong scroll_cell_width;

static BOOL scroll_fixture_ready(void) {
    NSString *path = [display_directory stringByAppendingPathComponent:@"scroll.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *receipt = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    unsigned top = [receipt[@"initial_top_row"] unsignedIntValue];
    if (![receipt[@"phase"] isEqualToString:@"ready"] || [receipt[@"rows_per_input"] unsignedIntValue] != 3 ||
        top <= 3 * (unsigned)limit || top > 65535) return NO;
    if (scroll_top_row && scroll_top_row != top) return NO;
    scroll_top_row = top;
    return YES;
}

static BOOL inject_scroll(NSView *view) {
    ScrollLatencyEvent *event = [ScrollLatencyEvent new];
    event.target = view.window;
    event.point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    [view scrollWheel:event];
    return YES;
}
