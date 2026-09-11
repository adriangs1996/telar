const Resources = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const ca = @import("../ca.zig");
const tls_transport = @import("../tls.zig");
const interception_policy = @import("../interception_policy.zig");
const metrics = @import("../metrics.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
authority: *ca.Authority,
roots: *tls_transport.Roots,
intercept_hosts: *const interception_policy.Policy,
telemetry: *metrics.Counters,
