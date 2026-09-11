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
pub fn validateWire(message: PaneProgress) !void {
    if (message.percent) |percent| {
        if (percent > 100) {
            return error.InvalidProgressPercent;
        }
    }

    switch (message.state) {
        .remove, .indeterminate => if (message.percent != null) {
            return error.UnexpectedProgressPercent;
        },
        .set => if (message.percent == null) {
            return error.MissingProgressPercent;
        },
        .@"error", .pause => {},
    }
}
