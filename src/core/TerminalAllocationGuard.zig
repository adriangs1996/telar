const TerminalAllocationGuard = @This();
const source_namespace = @import("diagnostics.zig");
previous: bool,

pub fn restore(guard: TerminalAllocationGuard) void {
    if (!source_namespace.enabled) {
        return;
    }
    source_namespace.terminal_allocation_scope = guard.previous;
}
