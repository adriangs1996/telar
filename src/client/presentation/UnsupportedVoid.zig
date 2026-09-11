const UnsupportedVoid = @This();
const Fixture = @import("Fixture.zig");
pub fn apply(_: *Fixture, _: anytype) !void {
    return error.UnsupportedTestEvent;
}
