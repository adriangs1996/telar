const CredentialType = @import("Credential.zig");
const std = @import("std");
const TestStore = @This();

expected: CredentialType,
live: bool = true,
lookups: usize = 0,

pub fn contains(store: *TestStore, credential: *const CredentialType) bool {
    store.lookups += 1;
    return store.live and std.meta.eql(store.expected, credential.*);
}
