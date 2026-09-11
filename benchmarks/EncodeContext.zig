const Fixture = @import("Fixture.zig");
const main = @import("main.zig");
const EncodeContext = @This();

fixture: *Fixture,
workload: main.Workload,
