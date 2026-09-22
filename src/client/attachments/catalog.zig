//! Bounded attachment identity, marker state and owned sensitive PNG storage.

const data = @import("model");
const std = @import("std");

pub fn optionalTargetEql(a: ?data.AttachmentTarget, b: ?data.AttachmentTarget) bool {
    if (a == null or b == null) {
        return a == null and b == null;
    }
    return std.meta.eql(a.?, b.?);
}
