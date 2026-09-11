const LivenessCapture = @This();
const identity = @import("../identity.zig");
const std = @import("std");
credential: identity.Credential,

pub fn contains(context: *anyopaque, credential: *const identity.Credential) bool {
    const capture: *const LivenessCapture = @ptrCast(@alignCast(context));

    return std.meta.eql(capture.credential, credential.*);
}
