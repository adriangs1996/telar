//! What both processes share about a reached limit: which errors mean a
//! bound ran out, and the notice text a reach shows as.
const std = @import("std");
const LimitReach = @import("LimitReach.zig");

/// Title of every limit notice.
pub const notice_title = "Limit reached";

/// Whether an error says a bound ran out rather than that something is
/// wrong: `*TooMany*`, `*Full`, `*Exceeded`, `*TooLarge`, `*TooLong`,
/// `BufferTooSmall` and `OutOfMemory`. A caller keeps what fit and reports
/// the limit; any other error keeps its caller's path.
///
/// ```zig
/// if (!limit_reached.isCapacityError(err)) return err;
/// ```
pub fn isCapacityError(err: anyerror) bool {
    if (err == error.BufferTooSmall or err == error.OutOfMemory) {
        return true;
    }

    const name = @errorName(err);
    return std.mem.indexOf(u8, name, "TooMany") != null or
        std.mem.endsWith(u8, name, "Full") or
        std.mem.endsWith(u8, name, "Exceeded") or
        std.mem.endsWith(u8, name, "TooLarge") or
        std.mem.endsWith(u8, name, "TooLong");
}

/// The reach a safety net reports for a capacity error nobody named: the
/// error's own name stands in for the limit's until a flow reports it.
///
/// ```zig
/// limit_reached.report(model, limit_reached.unnamed(err));
/// ```
pub fn unnamed(err: anyerror) LimitReach {
    return .{
        .limit = .{
            .name = @errorName(err),
            .value = 0,
        },
    };
}

test "capacity errors are told apart from bugs" {
    try std.testing.expect(isCapacityError(error.TooManyBarActions));
    try std.testing.expect(isCapacityError(error.AtlasFull));
    try std.testing.expect(isCapacityError(error.NativeCellBudgetExceeded));
    try std.testing.expect(isCapacityError(error.ImageTooLarge));
    try std.testing.expect(isCapacityError(error.StreamTooLong));
    try std.testing.expect(isCapacityError(error.BufferTooSmall));
    try std.testing.expect(isCapacityError(error.OutOfMemory));
    try std.testing.expect(!isCapacityError(error.InvalidPresentationCommit));
    try std.testing.expect(!isCapacityError(error.DeviceLost));
    try std.testing.expect(!isCapacityError(error.Unexpected));
}
