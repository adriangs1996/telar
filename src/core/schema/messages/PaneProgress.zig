const PaneProgress = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
state: source_namespace.PaneProgressState,
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
