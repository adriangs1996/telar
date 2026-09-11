const TestStore = @This();
const identity = @import("identity.zig");
const std = @import("std");
expected: identity.Credential,
live: bool = true,
lookups: usize = 0,

pub fn contains(store: *TestStore, credential: *const identity.Credential) bool {
    store.lookups += 1;
    return store.live and std.meta.eql(store.expected, credential.*);
}
