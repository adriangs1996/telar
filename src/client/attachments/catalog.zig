//! Bounded attachment identity, marker state and owned sensitive PNG storage.

const Target = @import("AttachmentTarget.zig");
const std = @import("std");

pub fn optionalTargetEql(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}
