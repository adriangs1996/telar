const term = @import("../../presentation/screen_support.zig");
const Capture = @This();

replies: usize = 0,

pub fn terminalResponse(self: *Capture, _: term.Event.TerminalResponse) !void {
    self.replies += 1;
}
