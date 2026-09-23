const id = @import("../id.zig");
const pane = @import("pane.zig");
const PaneProgress = @This();

pane_id: id.PaneId,
state: pane.PaneProgressState,
percent: ?u8 = null,

/// Rejects state and percentage combinations that have no protocol meaning.
///
/// ```zig
/// try progress.validateWire();
/// ```
pub fn validateWire(self: PaneProgress) !void {
    if (self.percent) |percent| {
        if (percent > 100) {
            return error.InvalidProgressPercent;
        }
    }

    switch (self.state) {
        .remove, .indeterminate => if (self.percent != null) {
            return error.UnexpectedProgressPercent;
        },
        .set => if (self.percent == null) {
            return error.MissingProgressPercent;
        },
        .@"error", .pause => {},
    }
}
