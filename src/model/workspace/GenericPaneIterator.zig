const core = @import("telar-core");
const Pane = @import("../panes/Pane.zig");

/// Preserves slot order and the caller's mutation authority. Example: `const Iterator = GenericPaneIterator(*const Pane);`
pub fn Type(comptime Pointer: type) type {
    if (Pointer != *Pane and Pointer != *const Pane) {
        @compileError("pane iteration requires a mutable or const Pane pointer");
    }

    return struct {
        const Self = @This();
        panes: *const [core.max_panes_per_tab]?*Pane,
        index: usize = 0,

        pub fn next(self: *Self) ?Pointer {
            while (self.index < self.panes.len) {
                const pane = self.panes[self.index];
                self.index += 1;
                if (pane) |value| {
                    return value;
                }
            }

            return null;
        }
    };
}
