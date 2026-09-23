const std = @import("std");
const Authority = @import("../Authority.zig");
const Roots = @import("../Roots.zig");
const Policy = @import("../Policy.zig");
const Counters = @import("../Counters.zig");
const Resources = @This();

io: std.Io,
gpa: std.mem.Allocator,
authority: *Authority,
roots: *Roots,
intercept_hosts: *const Policy,
telemetry: *Counters,
