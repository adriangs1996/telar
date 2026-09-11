const SessionType = @import("../Session.zig");
const FakeWriteSession = @This();

output: [512 * 1024]u8 = undefined,
len: usize = 0,

pub fn writeAll(fake: *FakeWriteSession, _: SessionType.Side, bytes: []const u8) bool {
    if (bytes.len > fake.output.len - fake.len) {
        return false;
    }
    @memcpy(fake.output[fake.len..][0..bytes.len], bytes);
    fake.len += bytes.len;
    return true;
}
