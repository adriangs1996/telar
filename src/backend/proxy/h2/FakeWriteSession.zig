const FakeWriteSession = @This();
const tls = @import("../tls.zig");
output: [512 * 1024]u8 = undefined,
len: usize = 0,

pub fn writeAll(fake: *FakeWriteSession, _: tls.Session.Side, bytes: []const u8) bool {
    if (bytes.len > fake.output.len - fake.len) {
        return false;
    }
    @memcpy(fake.output[fake.len..][0..bytes.len], bytes);
    fake.len += bytes.len;
    return true;
}
