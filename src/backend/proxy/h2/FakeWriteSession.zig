const Session = @import("../Session.zig");
const FakeWriteSession = @This();

output: [512 * 1024]u8 = undefined,
len: usize = 0,

pub fn writeAll(self: *FakeWriteSession, _: Session.Side, bytes: []const u8) bool {
    if (bytes.len > self.output.len - self.len) {
        return false;
    }
    @memcpy(self.output[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
    return true;
}
