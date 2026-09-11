const diagnostics = @import("diagnostics.zig");
const Guard = @This();

previous: diagnostics.Path,

pub fn restore(guard: Guard) void {
    if (!diagnostics.enabled) {
        return;
    }
    diagnostics.current_path = guard.previous;
}
