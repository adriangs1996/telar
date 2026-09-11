const Guard = @This();
const source_namespace = @import("diagnostics.zig");
previous: source_namespace.Path,

pub fn restore(guard: Guard) void {
    if (!source_namespace.enabled) {
        return;
    }
    source_namespace.current_path = guard.previous;
}
