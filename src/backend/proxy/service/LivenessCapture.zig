const Credential = @import("../Credential.zig");
const std = @import("std");
const LivenessCapture = @This();

credential: Credential,

pub fn contains(context: *anyopaque, credential: *const Credential) bool {
    const capture: *const LivenessCapture = @ptrCast(@alignCast(context));

    return std.meta.eql(capture.credential, credential.*);
}
