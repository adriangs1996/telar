const FakeSession = @import("../../proxy/http/FakeSession.zig");
const Session = @import("../../proxy/Session.zig");
const Fragment = @import("../../proxy/http/Fragment.zig");
const CountedRelay = @This();

fake: FakeSession,
writes: usize = 0,

/// Example: `const count = counted.read(.origin, buffer);`.
pub fn read(self: *CountedRelay, side: Session.Side, bytes: []u8) ?usize {
    return self.fake.read(side, bytes);
}

/// Example: `const forwarded = counted.writeAll(.child, bytes);`.
pub fn writeAll(self: *CountedRelay, side: Session.Side, bytes: []const u8) bool {
    self.writes += 1;
    return self.fake.writeAll(side, bytes);
}

/// Example: `counted.observe(fragment);`.
pub fn observe(_: *CountedRelay, _: Fragment) void {}
