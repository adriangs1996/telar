const Credential = @import("Credential.zig");
const std = @import("std");
const TestStore = @This();

expected: Credential,
live: bool = true,
lookups: usize = 0,

pub fn contains(self: *TestStore, credential: *const Credential) bool {
    self.lookups += 1;
    return self.live and std.meta.eql(self.expected, credential.*);
}
