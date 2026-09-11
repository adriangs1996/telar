const EncodeContext = @This();
const Fixture = @import("Fixture.zig");
const source_namespace = @import("main.zig");
fixture: *Fixture,
workload: source_namespace.Workload,
