const cellgrid = @import("cellgrid");

/// What was clickable, and which layer it belonged to.
///
/// Generic over the action so this can live down here rather than in the
/// client: a modal that swallows the clicks underneath it is a property of the
/// layering, not of the modal. A widget cannot implement it - by the time the
/// widget under the modal is asked, the decision has already been made wrong.
///
/// Fixed capacity on purpose. A frame wanting more clickable things than this
/// has a layout problem, and dropping the extras beats allocating on the draw
/// path.
pub fn Type(comptime Action: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Base, dropdown, modal, tooltip. Deeper stacks are a UI that has
        /// lost track of what the user is looking at.
        pub const max_layers = 8;

        pub const Entry = struct { rect: cellgrid.Rect, action: Action, layer: u8 };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        /// Where each layer stops clicks from falling through. Null means the
        /// layer is transparent outside its own registrations, which is what
        /// the base layer and a tooltip both want.
        blocks: [max_layers]?cellgrid.Rect = @splat(null),
        layer: u8 = 0,
        /// The deepest layer opened this frame, so `at` knows where to start.
        top: u8 = 0,

        /// Everything registered this frame, oldest first.
        ///
        /// Exposed because the useful test over a hit registry is an
        /// exhaustiveness one - every variant a UI can produce should appear
        /// somewhere in a drawn frame, and a control that is drawn but never
        /// registered is invisible to every other kind of test.
        pub fn registered(self: *const Self) []const Entry {
            return self.entries[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.layer = 0;
            self.top = 0;
            self.blocks = @splat(null);
        }

        /// Opens a layer above the current one.
        ///
        /// `swallows` is the region in which this layer answers for every
        /// point, registered or not. A modal passes its own frame, so a click
        /// on its blank interior lands on the modal instead of reaching the
        /// list behind it. Pass null for an overlay that should not steal
        /// clicks it has no control under - a tooltip, a drag ghost.
        pub fn beginLayer(self: *Self, swallows: ?cellgrid.Rect) void {
            if (self.layer + 1 >= max_layers) {
                return;
            }
            self.layer += 1;
            self.top = @max(self.top, self.layer);
            self.blocks[self.layer] = swallows;
        }

        pub fn endLayer(self: *Self) void {
            if (self.layer == 0) {
                return;
            }
            self.layer -= 1;
        }

        pub fn add(self: *Self, rect: cellgrid.Rect, action: Action) void {
            if (self.len == capacity) {
                return;
            }
            if (rect.isEmpty()) {
                return;
            }
            self.entries[self.len] = .{ .rect = rect, .action = action, .layer = self.layer };
            self.len += 1;
        }

        /// What a click at (x, y) hits, if anything.
        ///
        /// Top layer down, and within a layer the newest registration wins -
        /// so a chip drawn over a task row takes the click rather than the row
        /// underneath it. A layer that swallows the point ends the search
        /// there even when it registered nothing at it, which is the whole
        /// difference between an overlay and a modal.
        pub fn at(self: *const Self, x: u16, y: u16) ?Action {
            var layer: i16 = self.top;
            while (layer >= 0) : (layer -= 1) {
                const current: u8 = @intCast(layer);
                var index = self.len;
                while (index > 0) {
                    index -= 1;
                    const entry = self.entries[index];
                    if (entry.layer != current) {
                        continue;
                    }
                    if (entry.rect.contains(x, y)) {
                        return entry.action;
                    }
                }
                if (self.blocks[current]) |region| {
                    if (region.contains(x, y)) {
                        return null;
                    }
                }
            }
            return null;
        }
    };
}
