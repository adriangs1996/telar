const CredentialType = @import("../Credential.zig");
const std = @import("std");
const LivenessCapture = @This();

credential: CredentialType,

pub fn contains(context: *anyopaque, credential: *const CredentialType) bool {
    const capture: *const LivenessCapture = @ptrCast(@alignCast(context));

    return std.meta.eql(capture.credential, credential.*);
}
