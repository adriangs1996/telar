const diagnostics = @import("diagnostics.zig");
const Guard = @This();

previous: diagnostics.Path,

pub fn restore(self: Guard) void {
    if (!diagnostics.enabled) {
        return;
    }
    diagnostics.current_path = self.previous;
}
