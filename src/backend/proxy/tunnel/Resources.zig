const std = @import("std");
const AuthorityType = @import("../Authority.zig");
const RootsType = @import("../Roots.zig");
const PolicyType = @import("../Policy.zig");
const CountersType = @import("../Counters.zig");
const Resources = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *AuthorityType,
roots: *RootsType,
intercept_hosts: *const PolicyType,
telemetry: *CountersType,
