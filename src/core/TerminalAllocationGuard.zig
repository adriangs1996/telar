const diagnostics = @import("diagnostics.zig");
const TerminalAllocationGuard = @This();

previous: bool,

pub fn restore(guard: TerminalAllocationGuard) void {
    if (!diagnostics.enabled) {
        return;
    }
    diagnostics.terminal_allocation_scope = guard.previous;
}
