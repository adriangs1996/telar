const std = @import("std");
const localca = @import("localca");
const Authority = localca.Authority;
const Roots = localca.Roots;
const Policy = @import("../Policy.zig");
const Counters = @import("../Counters.zig");
const Resources = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *Authority,
roots: *Roots,
intercept_hosts: *const Policy,
telemetry: *Counters,
