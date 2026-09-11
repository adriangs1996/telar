const Capture = @This();
const term = @import("../../presentation/root.zig").screen;
replies: usize = 0,

pub fn terminalResponse(capture: *Capture, _: term.Event.TerminalResponse) !void {
    capture.replies += 1;
}
