const term = @import("../../presentation/screen_support.zig");
const Capture = @This();

replies: usize = 0,

pub fn terminalResponse(capture: *Capture, _: term.Event.TerminalResponse) !void {
    capture.replies += 1;
}
